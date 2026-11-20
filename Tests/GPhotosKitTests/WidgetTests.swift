import CoreGraphics
import Foundation
import Testing

@testable import GPhotosKit

@Suite("Widgets")
struct WidgetTests {
  @Test("Widget links open photos, people and the backup, and nothing else")
  func links() {
    for link in [WidgetLink.photo("ABC/L0/001"), .photo("g:AF1Qip_x"), .person(42), .backup] {
      #expect(WidgetLink(url: link.url) == link)
    }
    #expect(WidgetLink(url: URL(string: "gphotosapp://activity?kind=failed")!) == nil)
    #expect(WidgetLink(url: URL(string: "gphotosapp://photo")!) == nil)
    #expect(WidgetLink(url: URL(string: "https://photo?id=1")!) == nil)
  }

  @Test("Photos change on the hour, the same one at the same time everywhere")
  func rotation() {
    let hour = Date(timeIntervalSince1970: 3_600 * 1_000)
    #expect(WidgetRotation.index(count: 3, at: hour) == 1_000 % 3)
    #expect(WidgetRotation.index(count: 3, at: hour.addingTimeInterval(3_599)) == 1_000 % 3)
    #expect(WidgetRotation.index(count: 3, at: hour.addingTimeInterval(3_600)) == 1_001 % 3)
    #expect(WidgetRotation.index(count: 0, at: hour) == 0)
    let hours = WidgetRotation.hours(from: hour.addingTimeInterval(600), count: 3)
    #expect(hours.count == 3)
    #expect(hours[0] == hour.addingTimeInterval(600))
    #expect(hours[1] == hour.addingTimeInterval(3_600))
  }

  @Test("A filled photo keeps its focus in view and never leaves a gap")
  func fill() {
    let container = CGSize(width: 364, height: 170)
    // A portrait photo with a face near the top.
    let frame = PhotoWidgetView.fill(
      CGSize(width: 900, height: 1_200), in: container, focus: CGPoint(x: 0.5, y: 0.2), keepsFocusHigh: true)
    #expect(frame.width == 364 && abs(frame.height - 485.33) < 0.01)
    let faceY = frame.minY + 0.2 * frame.height
    #expect(faceY > 0 && faceY < container.height)
    #expect(frame.minY <= 0 && frame.maxY >= container.height)
    // Without a focus the middle shows.
    let centred = PhotoWidgetView.fill(
      CGSize(width: 900, height: 1_200), in: container, focus: CGPoint(x: 0.5, y: 0.5), keepsFocusHigh: false)
    #expect(abs(centred.midY - container.height / 2) < 0.01)
    // A focus at the very edge is clamped rather than pulling the photo off the widget.
    let edge = PhotoWidgetView.fill(
      CGSize(width: 900, height: 1_200), in: container, focus: CGPoint(x: 0.5, y: 1), keepsFocusHigh: false)
    #expect(abs(edge.maxY - container.height) < 0.01)
  }

  @Test("The widget folder keeps what the app wrote and drops images no longer listed")
  func store() throws {
    let directory = TestTemporaryDirectory.root.appending(path: "Widgets-\(UUID().uuidString)")
    let photo = WidgetPhoto(itemID: "a", file: "a.jpg", date: Date(timeIntervalSince1970: 1_000), focus: CGPoint(x: 0.3, y: 0.4))
    let snapshot = WidgetPhotoSnapshot(
      generatedAt: Date(timeIntervalSince1970: 2_000),
      memories: [WidgetPhotoSet(id: "m", kind: .onThisDay, title: "On This Day", subtitle: "", photos: [photo])])
    try WidgetStore.write(snapshot, in: directory)
    #expect(WidgetStore.photos(in: directory) == snapshot)
    let backup = WidgetBackupSnapshot(
      title: "Up to Date", subtitle: "", symbol: "checkmark", tone: "green", isSignedIn: true, isHealthy: true,
      backedUpCount: 12)
    try WidgetStore.write(backup, in: directory)
    #expect(WidgetStore.backup(in: directory)?.sameContent(as: backup) == true)
    for name in ["a.jpg", "old.jpg"] { try Data([1]).write(to: directory.appendingPathComponent(name)) }
    WidgetStore.prune(keeping: ["a.jpg"], in: directory)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("a.jpg").path))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("old.jpg").path))
    #expect(WidgetPublisher.fileName(for: "ABC/L0/001") == WidgetPublisher.fileName(for: "ABC/L0/001"))
    #expect(!WidgetPublisher.fileName(for: "ABC/L0/001").contains("/"))
  }

  @Test("Widget photos come from the best non-utility items, framed on the person's face")
  func indexQueries() async throws {
    let store = LibraryIndexStore(
      directory: TestTemporaryDirectory.root.appending(path: "WidgetIndex-\(UUID().uuidString)"))
    for (id, score, utility) in [("best", Float(0.9), false), ("receipt", 0.95, true), ("okay", 0.4, false)] {
      var analysis = ItemAnalysis()
      analysis.aesthetics = score
      analysis.isUtility = utility
      analysis.faces = [DetectedFace(rect: CGRect(x: 0.2, y: 0.1, width: 0.2, height: 0.3), featurePrint: Data([1]))]
      try await store.save(ItemMetadata(id: id, date: Date(timeIntervalSince1970: 5_000), words: []), analysis: analysis)
    }
    #expect(try await store.featuredIDs(limit: 10) == ["best", "okay"])
    let scores = try await store.photoScores(ids: ["best", "receipt", "missing"])
    #expect(scores["receipt"]?.isUtility == true)
    #expect(scores["best"]?.aesthetics == 0.9)
    #expect(scores["best"]?.date == Date(timeIntervalSince1970: 5_000))
    #expect(scores["missing"] == nil)

    let faces = try await store.faces()
    try await store.assignFaces(Dictionary(uniqueKeysWithValues: faces.map { ($0.id, Int64(7)) }))
    let centers = try await store.faceCenters(person: 7, ids: ["best", "okay"])
    #expect(centers.count == 2)
    #expect(abs((centers["best"]?.x ?? 0) - 0.3) < 0.0001)
    #expect(abs((centers["best"]?.y ?? 0) - 0.22) < 0.0001)
    #expect(try await store.faceCenters(person: 8, ids: ["best"]).isEmpty)
  }
}
