import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import MapKit
import UniformTypeIdentifiers
import WidgetKit
import os

/// Picks the photos the widgets show and keeps the Backup widget's status current. The
/// app calls it as the library and the backup change; it writes to the App Group and asks
/// WidgetKit to reload.
@MainActor
public final class WidgetPublisher {
  public static let shared = WidgetPublisher()

  /// Memories change by the day and People slowly; this keeps a running app from
  /// rendering the photos again on every library change.
  static let refreshInterval: TimeInterval = 30 * 60
  /// Big enough for the large widget on a Pro Max iPhone (about 1,100 pixels across) once
  /// the widget crops it to its shape, small enough for a widget's memory.
  static let imageSide = 1_000

  private let directory: URL
  private var photoTask: Task<Void, Never>?
  private var backupTask: Task<Void, Never>?
  private var pendingBackup: WidgetBackupSnapshot?
  private var writtenBackup: WidgetBackupSnapshot?
  private let logger = Logger(subsystem: "org.gphotosapp.gphotos", category: "Widgets")

  init(directory: URL = WidgetStore.directory) {
    self.directory = directory
    writtenBackup = WidgetStore.backup(in: directory)
  }

  // MARK: Photos

  /// The library changed: picks new photos when the last pick is from another day or a
  /// while ago. The work waits a little so launch and the first grid go first.
  public func libraryChanged(_ library: UnifiedLibraryModel) {
    guard library.isLoaded, library.itemCount > 0, photoTask == nil else { return }
    let previous = WidgetStore.photos(in: directory)
    var isFresh =
      previous.map {
        !$0.isEmpty && Calendar.current.isDateInToday($0.generatedAt)
          && Date().timeIntervalSince($0.generatedAt) < Self.refreshInterval
      } ?? false
    #if DEBUG
      // `-UIRefreshWidgets YES` picks again at launch, for reviewing the widgets.
      if UserDefaults.standard.bool(forKey: "UIRefreshWidgets") { isFresh = false }
    #endif
    if isFresh { return }
    photoTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(previous == nil ? 5 : 20))
      if !Task.isCancelled { await self?.publishPhotos(from: library) }
      self?.photoTask = nil
    }
  }

  func publishPhotos(from library: UnifiedLibraryModel) async {
    let store = SiriLibrary.shared.store
    var memories: [WidgetPhotoSet] = []
    for memory in await Memory.find(in: library) where memories.count < 6 {
      let photos = await pick(memory.idList.values, count: 3, store: store, library: library)
      guard !photos.isEmpty else { continue }
      switch memory.kind {
      case .onThisDay:
        memories.append(
          WidgetPhotoSet(
            id: memory.id, kind: .onThisDay, title: String(localized: "On This Day"),
            subtitle: memory.date.formatted(.dateTime.day().month(.abbreviated).year()), photos: photos))
      case .trip(let latitude, let longitude):
        let place = await Self.placeName(latitude: latitude, longitude: longitude)
        memories.append(
          WidgetPhotoSet(
            id: memory.id, kind: .trip, title: place ?? memory.title,
            subtitle: place == nil ? String(localized: "Trip") : memory.title, photos: photos))
      }
    }
    // Days without memories still get photos: the best ones, a different few each day.
    if memories.count < 3 {
      let featured = (try? await store.featuredIDs(limit: 400)) ?? []
      var generator = SeededGenerator(seed: UInt64(Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0))
      let photos = await pick(featured.shuffled(using: &generator), count: 8, store: store, library: library, keepsOrder: true)
      if !photos.isEmpty {
        memories.append(
          WidgetPhotoSet(
            id: "featured", kind: .featured, title: String(localized: "Featured Photos"), subtitle: "", photos: photos))
      }
    }

    var people: [WidgetPhotoSet] = []
    for person in ((try? await store.people()) ?? []).prefix(8) {
      let ids = Array(((try? await store.ids(ofPerson: person.id)) ?? []).prefix(300))
      // Their best photos among the latest few hundred, so a widget feels current, cropped
      // around their face.
      let faces = (try? await store.faceCenters(person: person.id, ids: ids)) ?? [:]
      let photos = await pick(ids, count: 5, store: store, library: library, focus: faces)
      guard !photos.isEmpty else { continue }
      people.append(
        WidgetPhotoSet(
          id: "person-\(person.id)", kind: .person, title: person.name ?? "",
          subtitle: ProductCopy.inflected("^[\(person.faceCount) photo](inflect: true)"), photos: photos,
          personID: person.id))
    }

    let snapshot = WidgetPhotoSnapshot(memories: memories, people: people)
    do {
      try WidgetStore.write(snapshot, in: directory)
      WidgetStore.prune(keeping: Set((memories + people).flatMap(\.photos).map(\.file)), in: directory)
      WidgetCenter.shared.reloadTimelines(ofKind: WidgetStore.memoriesKind)
      WidgetCenter.shared.reloadTimelines(ofKind: WidgetStore.peopleKind)
      logger.info("Widgets: \(memories.count) memories, \(people.count) people")
    } catch {
      logger.error("Widgets: couldn't save photos: \(error.localizedDescription)")
    }
  }

  /// The best `count` of `ids` that are in the library, with a saved image each. Items the
  /// index calls screenshots or documents are left out; folder files have no image source.
  private func pick(
    _ ids: [String], count: Int, store: LibraryIndexStore, library: UnifiedLibraryModel, keepsOrder: Bool = false,
    focus: [String: CGPoint] = [:]
  ) async -> [WidgetPhoto] {
    let candidates = ids.filter { !$0.hasPrefix(FolderItemInfo.idPrefix) && !library.positions(of: [$0]).isEmpty }
    let scores = (try? await store.photoScores(ids: candidates)) ?? [:]
    var ranked = candidates.filter { scores[$0]?.isUtility != true }
    if !keepsOrder {
      ranked.sort { (scores[$0]?.aesthetics ?? -1) > (scores[$1]?.aesthetics ?? -1) }
    }
    var photos: [WidgetPhoto] = []
    for id in ranked where photos.count < count {
      guard let file = await saveImage(indexID: id, library: library) else { continue }
      photos.append(WidgetPhoto(itemID: id, file: file, date: scores[id]?.date ?? Date(), focus: focus[id]))
    }
    return photos
  }

  /// Saves the item's image as a JPEG named after its id, reusing one already saved.
  private func saveImage(indexID: String, library: UnifiedLibraryModel) async -> String? {
    let name = Self.fileName(for: indexID)
    let url = directory.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: url.path) { return name }
    guard let position = library.positions(of: [indexID]).first,
      let image = await Self.image(id: library.itemID(at: position), source: library.thumbnailSource)
    else { return nil }
    let side = Self.imageSide
    let saved = await Task.detached(priority: .utility) { () -> Bool in
      guard let data = Self.jpeg(image, maxPixel: side) else { return false }
      try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      return (try? data.write(to: url, options: .atomic)) != nil
    }.value
    return saved ? name : nil
  }

  nonisolated static func fileName(for indexID: String) -> String {
    SHA256.hash(data: Data(indexID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".jpg"
  }

  /// The source's final image at viewer size, or the best it had after a while.
  private static func image(id: String, source: any ThumbnailSource) async -> CGImage? {
    let request = ImageWait()
    return await withCheckedContinuation { continuation in
      request.begin(continuation)
      let token = source.requestImage(
        id: id, pixelSize: CGSize(width: imageSide, height: imageSide), quality: .display
      ) { image, isFinal in
        request.offer(image, isFinal: isFinal)
      }
      request.attach(token)
      Task {
        try? await Task.sleep(for: .seconds(20))
        request.finish()
      }
    }
  }

  nonisolated static func jpeg(_ image: CGImage, maxPixel: Int) -> Data? {
    var image = image
    let longest = max(image.width, image.height)
    if longest > maxPixel {
      let scale = Double(maxPixel) / Double(longest)
      let width = Int((Double(image.width) * scale).rounded())
      let height = Int((Double(image.height) * scale).rounded())
      guard
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
      else { return nil }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      guard let scaled = context.makeImage() else { return nil }
      image = scaled
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }

  private static func placeName(latitude: Double, longitude: Double) async -> String? {
    guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude))
    else { return nil }
    let item = try? await request.mapItems.first
    return item?.addressRepresentations?.cityName ?? item?.addressRepresentations?.regionName
  }

  // MARK: Backup

  /// The backup status changed. Scans come and go all the time and aren't shown; a new
  /// kind of status is written within moments, progress within the minute.
  public func backupChanged(_ status: BackupStatus, backedUpCount: Int) {
    if case .scanning = status { return }
    let snapshot = WidgetBackupSnapshot(
      title: status.title, subtitle: status.subtitle, symbol: status.symbol, tone: status.tone.rawValue,
      isSignedIn: status != .signedOut, isHealthy: status.tone == .green, backedUpCount: backedUpCount)
    let base = pendingBackup ?? writtenBackup
    if let base, base.sameContent(as: snapshot) { return }
    let isNewKind = base?.symbol != snapshot.symbol || base?.title.prefix(8) != snapshot.title.prefix(8)
    pendingBackup = snapshot
    if isNewKind { backupTask?.cancel() } else if backupTask != nil { return }
    backupTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(isNewKind ? 2 : 60))
      guard !Task.isCancelled, let self, let pending = self.pendingBackup else { return }
      self.pendingBackup = nil
      self.backupTask = nil
      self.writeBackup(pending)
    }
  }

  private func writeBackup(_ snapshot: WidgetBackupSnapshot) {
    guard writtenBackup.map({ !$0.sameContent(as: snapshot) }) ?? true else { return }
    do {
      try WidgetStore.write(snapshot, in: directory)
      writtenBackup = snapshot
      WidgetCenter.shared.reloadTimelines(ofKind: WidgetStore.backupKind)
    } catch {
      logger.error("Widgets: couldn't save the backup status: \(error.localizedDescription)")
    }
  }
}

/// One image request's result: the final image, or the best delivered before the timeout.
private final class ImageWait: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<CGImage?, Never>?
  private var best: CGImage?
  private var token: ImageRequestToken?
  private var isDone = false

  func begin(_ continuation: CheckedContinuation<CGImage?, Never>) {
    lock.withLock { self.continuation = continuation }
  }

  func attach(_ token: ImageRequestToken) {
    let cancelNow = lock.withLock { () -> Bool in
      self.token = token
      return isDone
    }
    if cancelNow { token.cancel() }
  }

  func offer(_ image: CGImage, isFinal: Bool) {
    lock.withLock { best = image }
    if isFinal { finish() }
  }

  func finish() {
    let (continuation, image, token) = lock.withLock { () -> (CheckedContinuation<CGImage?, Never>?, CGImage?, ImageRequestToken?) in
      guard !isDone else { return (nil, nil, nil) }
      isDone = true
      defer { self.continuation = nil }
      return (self.continuation, best, self.token)
    }
    token?.cancel()
    continuation?.resume(returning: image)
  }
}

/// A repeatable shuffle, so the featured photos change once a day, not on every pick.
private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
