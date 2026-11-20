import CoreGraphics
import Foundation
import Photos
import Testing

@testable import GPhotosKit

@Suite("Library browsing")
struct LibraryBrowsingTests {
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
  }

  @Test("Months cover every index once, newest first, undated items joining the month before")
  func timelineMonths() {
    let dates: [Date?] = [
      Self.date(2026, 10, 20), Self.date(2026, 10, 2), nil, Self.date(2026, 9, 30),
      Self.date(2025, 12, 31), Self.date(2025, 1, 1),
    ]
    let index = TimelineIndex.build(count: dates.count, calendar: Self.calendar) { dates[$0] }
    #expect(index.months.map(\.range) == [0..<3, 3..<4, 4..<5, 5..<6])
    #expect(index.month(containing: 2)?.start == Self.calendar.date(from: DateComponents(year: 2026, month: 10)))
    #expect(index.month(containing: 5)?.range == 5..<6)
    #expect(index.month(containing: 6) == nil)
    #expect(index.years(calendar: Self.calendar).map(\.range) == [0..<4, 4..<6])
  }

  @Test("Leading undated items belong to the first month")
  func timelineLeadingUndated() {
    let dates: [Date?] = [nil, nil, Self.date(2026, 1, 5)]
    let index = TimelineIndex.build(count: dates.count, calendar: Self.calendar) { dates[$0] }
    #expect(index.months.map(\.range) == [0..<3])
    #expect(TimelineIndex.build(count: 2, calendar: Self.calendar) { _ in nil }.months.isEmpty)
  }

  @Test("Map pins group nearby points and keep the busiest cells")
  func placeClusters() throws {
    let points = [
      PlacePoint(id: "a", latitude: 48.85, longitude: 2.35),
      PlacePoint(id: "b", latitude: 48.86, longitude: 2.34),
      PlacePoint(id: "c", latitude: 40.71, longitude: -74.0),
    ]
    let clusters = PlaceClusters.make(points, cellDegrees: 1)
    #expect(clusters.count == 2)
    #expect(clusters[0].ids == ["a", "b"])
    #expect(abs(clusters[0].latitude - 48.855) < 0.0001)
    #expect(PlaceClusters.make(points, cellDegrees: 1, limit: 1).count == 1)
    #expect(PlaceClusters.make(points, cellDegrees: 0.001).count == 3)
    // A map that settles a hair wider or narrower keeps its grid, so pins stay put.
    #expect(PlaceClusters.cellDegrees(forSpan: 10) == PlaceClusters.cellDegrees(forSpan: 11.5))
    #expect(PlaceClusters.cellDegrees(forSpan: 10) == 2)
    #expect(PlaceClusters.region(containing: []) == nil)
    #expect(PlaceClusters.region(containing: points) != nil)
    // A trip far away doesn't pull the map off the places most photos were taken.
    let home = (0..<38).map { PlacePoint(id: "h\($0)", latitude: 23.8 + Double($0) * 0.01, longitude: 90.4) }
    let trips = [PlacePoint(id: "is", latitude: 64.1, longitude: -21.9), PlacePoint(id: "ny", latitude: 40.7, longitude: -74)]
    let region = try #require(PlaceClusters.region(containing: home + trips))
    #expect(abs(region.center.latitude - 24) < 1 && abs(region.center.longitude - 90.4) < 1)
  }

  @Test("Changed device items merge into the saved order, keeping undated items in place")
  func deviceSnapshotMerge() {
    func info(_ id: String, _ seconds: TimeInterval) -> DeviceItemInfo {
      DeviceItemInfo(
        localIdentifier: id, date: Date(timeIntervalSinceReferenceDate: seconds), width: 1, height: 1, isVideo: false,
        isFavorite: false)
    }
    // An undated first asset carries distantFuture; a new photo must not jump above it.
    let saved = [
      DeviceItemInfo(
        localIdentifier: "undated", date: .distantFuture, width: 1, height: 1, isVideo: false, isFavorite: false),
      info("b", 300), info("c", 200), info("d", 100),
    ]
    let merged = DeviceInfoSnapshot.merge(saved, [info("new", 400), info("mid", 250), info("tie", 200)])
    #expect(merged.map(\.localIdentifier) == ["undated", "new", "b", "mid", "c", "tie", "d"])
    #expect(DeviceInfoSnapshot.merge(saved, []).map(\.localIdentifier) == saved.map(\.localIdentifier))
  }

  @Test("Map pins cover the visible area, growing cells instead of dropping photos")
  func placeClustersInArea() {
    // A city grid of 20 x 20 spots, plus photos elsewhere in the world.
    var points = (0..<400).map { index in
      PlacePoint(id: "p\(index)", latitude: 48.8 + Double(index / 20) * 0.01, longitude: 2.3 + Double(index % 20) * 0.01)
    }
    points += (0..<300).map { PlacePoint(id: "w\($0)", latitude: -40 + Double($0 % 60), longitude: -170 + Double($0)) }
    let area = PlaceClusters.Area(centerLatitude: 48.9, centerLongitude: 2.4, latitudeRadius: 0.2, longitudeRadius: 0.2)
    let clusters = PlaceClusters.make(points, cellDegrees: 0.005, area: area, limit: 150)
    #expect(clusters.count <= 150)
    #expect(clusters.reduce(0) { $0 + $1.ids.count } == 400)
    #expect(PlaceClusters.Area(centerLatitude: 0, centerLongitude: 170, latitudeRadius: 5, longitudeRadius: 20) == nil)
  }

  @Test("The viewer fits the whole photo")
  func aspectFit() {
    #expect(AspectFit.size(for: CGSize(width: 4000, height: 3000), in: CGSize(width: 400, height: 800)) == CGSize(width: 400, height: 300))
    #expect(AspectFit.size(for: CGSize(width: 1000, height: 3000), in: CGSize(width: 400, height: 600)) == CGSize(width: 200, height: 600))
    #expect(AspectFit.size(for: .zero, in: CGSize(width: 10, height: 10)) == CGSize(width: 10, height: 10))
  }

  @Test("Filters become PhotoKit predicates")
  func filters() {
    #expect(LibraryFetch.predicate(for: .all, backedUpIDs: []) == nil)
    #expect(LibraryFetch.predicate(for: .favorites, backedUpIDs: [])?.predicateFormat == "isFavorite == 1")
    let notBackedUp = LibraryFetch.predicate(for: .notBackedUp, backedUpIDs: ["x"])?.predicateFormat ?? ""
    #expect(notBackedUp.hasPrefix("NOT localIdentifier IN"))
    #expect(LibraryScope.album(id: "1", title: "Trip").isDateOrdered == false)
    #expect(LibraryScope.all.isDateOrdered)
  }
}

@Suite("Merged timeline")
struct TimelineMergeTests {
  private func device(_ id: String, _ seconds: TimeInterval, video: Bool = false, favorite: Bool = false) -> DeviceItemInfo {
    DeviceItemInfo(
      localIdentifier: id, date: Date(timeIntervalSince1970: seconds), width: 4032, height: 3024, isVideo: video,
      isFavorite: favorite)
  }

  private func cloud(_ key: String, _ seconds: TimeInterval, width: Int = 4032, favorite: Bool = false) -> RemoteItemSummary {
    RemoteItemSummary(
      mediaKey: key, dedupKey: key, sha1: nil, kind: .photo, takenAt: Date(timeIntervalSince1970: seconds),
      contentVersion: 0, durationMs: nil, isFavorite: favorite, trashedAt: nil, width: width, height: 3024)
  }

  @Test("Items on both show once as the device copy, newest last")
  func mergesAndDeduplicates() {
    let devices = [device("d3", 300), device("d2", 200), device("d1", 100)]
    let clouds = [cloud("c4", 400), cloud("c3", 300.2, width: 1), cloud("c2", 200), cloud("c0", 50)]
    // d3 was uploaded by this app as c3; d2 matches c2 by capture second and size.
    let entries = TimelineMerge.merge(device: devices, cloud: clouds, uploadedMediaKeys: ["d3": ["c3"]])
    #expect(entries == [.cloud(3), .device(2, cloud: nil), .device(1, cloud: 2), .device(0, cloud: 1), .cloud(0)])
  }

  @Test("Folder files join the timeline, once with their Google Photos copy, dated by it")
  func folderFiles() {
    let devices = [device("d2", 200)]
    let clouds = [cloud("c3", 300), cloud("c1", 100)]
    let files = [
      // Uploaded as c1; its own date is a copy date, the Google copy has the real one.
      FolderItemInfo(path: "/f/a.heic", date: Date(timeIntervalSince1970: 900), size: 1, isVideo: false),
      FolderItemInfo(path: "/f/b.mov", date: Date(timeIntervalSince1970: 250), size: 1, isVideo: true),
    ]
    let entries = TimelineMerge.merge(
      device: devices, cloud: clouds, uploadedMediaKeys: [:], folder: files, uploadedFileKeys: ["/f/a.heic": "c1"])
    #expect(entries == [.folder(0, cloud: 1), .device(0, cloud: nil), .folder(1, cloud: nil), .cloud(0)])
    #expect(
      TimelineMerge.merge(
        device: devices, cloud: clouds, uploadedMediaKeys: [:], folder: files, uploadedFileKeys: ["/f/a.heic": "c1"],
        filter: .notBackedUp) == [.device(0, cloud: nil), .folder(1, cloud: nil)])
    #expect(
      TimelineMerge.merge(device: [], cloud: [], uploadedMediaKeys: [:], folder: files, filter: .videos)
        == [.folder(1, cloud: nil)])
  }

  @Test("A still and a video sharing a name are one Live Photo; files sort newest first")
  func folderLivePhotos() {
    func file(_ name: String, _ seconds: TimeInterval) -> LocalMediaFile {
      let date = Date(timeIntervalSince1970: seconds)
      return LocalMediaFile(url: URL(fileURLWithPath: "/f/" + name), size: 1, created: date, modified: date)
    }
    let items = FolderLibrary.items(from: [
      file("IMG_1.HEIC", 100), file("IMG_1.MOV", 100), file("clip.mov", 300), file("IMG_2.jpg", 200),
    ])
    #expect(items.map(\.fileName) == ["clip.mov", "IMG_2.jpg", "IMG_1.HEIC"])
    #expect(items.last?.isLivePhoto == true)
    #expect(items.first?.isVideo == true)
  }

  @Test("Same-second bursts aren't paired by guesswork")
  func burstsStaySeparate() {
    let devices = [device("burst1", 500), device("burst2", 500)]
    let clouds = [cloud("only", 500)]
    let entries = TimelineMerge.merge(device: devices, cloud: clouds, uploadedMediaKeys: [:])
    #expect(entries.contains(.cloud(0)))
    #expect(!entries.contains { if case .device(_, cloud: .some) = $0 { true } else { false } })
  }

  @Test("Filters apply across both libraries")
  func filters() {
    let devices = [device("d2", 200, favorite: true), device("d1", 100, video: true)]
    let clouds = [cloud("c3", 300), cloud("c2", 200, favorite: false)]
    #expect(
      TimelineMerge.merge(device: devices, cloud: clouds, uploadedMediaKeys: [:], filter: .cloudOnly) == [.cloud(0)])
    #expect(
      TimelineMerge.merge(device: devices, cloud: clouds, uploadedMediaKeys: [:], filter: .notBackedUp)
        == [.device(1, cloud: nil)])
    #expect(
      TimelineMerge.merge(device: devices, cloud: clouds, uploadedMediaKeys: [:], filter: .favorites)
        == [.device(0, cloud: 1)])
    #expect(
      TimelineMerge.merge(device: devices, cloud: clouds, uploadedMediaKeys: [:], filter: .videos)
        == [.device(1, cloud: nil)])
  }

  @Test("Live Photos and screenshots filter both libraries, and screenshots can be hidden")
  func mediaTypes() {
    let live = PHAssetMediaSubtype.photoLive.rawValue
    let shot = PHAssetMediaSubtype.photoScreenshot.rawValue
    let devices = [
      DeviceItemInfo(
        localIdentifier: "live", date: Date(timeIntervalSince1970: 300), width: 4032, height: 3024, isVideo: false,
        isFavorite: false, subtypes: live),
      DeviceItemInfo(
        localIdentifier: "shot", date: Date(timeIntervalSince1970: 200), width: 1179, height: 2556, isVideo: false,
        isFavorite: false, subtypes: shot),
    ]
    var motion = cloud("motion", 150, width: 640)
    motion = RemoteItemSummary(
      mediaKey: "motion", dedupKey: "motion", sha1: nil, kind: .motionPhoto, takenAt: motion.takenAt,
      contentVersion: 0, durationMs: nil, isFavorite: false, trashedAt: nil, width: 640, height: 480)
    var screenshot = cloud("cloudShot", 100, width: 720)
    screenshot.fileName = "Screenshot_20240101.png"
    let clouds = [motion, screenshot]
    #expect(
      TimelineMerge.merge(device: devices, cloud: clouds, uploadedMediaKeys: [:], filter: .livePhotos)
        == [.cloud(0), .device(0, cloud: nil)])
    #expect(
      TimelineMerge.merge(device: devices, cloud: clouds, uploadedMediaKeys: [:], filter: .screenshots)
        == [.cloud(1), .device(1, cloud: nil)])
    #expect(
      TimelineMerge.merge(device: devices, cloud: clouds, uploadedMediaKeys: [:], hidesScreenshots: true)
        == [.cloud(0), .device(0, cloud: nil)])
    // The Screenshots filter still shows them while they're hidden elsewhere.
    #expect(
      TimelineMerge.merge(
        device: devices, cloud: clouds, uploadedMediaKeys: [:], filter: .screenshots, hidesScreenshots: true
      ).count == 2)
  }

  @Test("Upload records map assets to media keys, preferring the still")
  func uploadedKeys() {
    var still = TransferRecord(id: "1", filename: "a", mediaType: "Photo", status: .sent, assetLocalIdentifier: "A")
    still.mediaKeysByAccount = ["me@x.com": "STILL"]
    var raw = TransferRecord(id: "2", filename: "a", mediaType: "Photo", status: .sent, assetLocalIdentifier: "A")
    raw.mediaKeysByAccount = ["me@x.com": "RAW"]
    raw.resourceRole = .alternatePhoto
    #expect(UnifiedLibraryModel.uploadEvidence([still, raw], email: "me@x.com").keys == ["A": ["STILL"]])
    #expect(UnifiedLibraryModel.uploadEvidence([raw, still], email: "me@x.com").keys == ["A": ["STILL"]])
  }
}
