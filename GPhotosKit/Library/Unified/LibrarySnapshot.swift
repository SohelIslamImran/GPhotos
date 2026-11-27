import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// The Library as it last looked at its newest items, saved as the app goes to the
/// background and drawn on the first frame of the next launch, as Photos does, until the
/// live grid has drawn and fades in over it. Only kept for the grid the app opens to:
/// All, at its newest row, at the default zoom.
public struct LibrarySnapshot: Sendable {
  public struct Info: Codable, Sendable, Equatable {
    /// The grid's size in points, and the screen scale the image was drawn at.
    public var width: CGFloat
    public var height: CGFloat
    public var scale: CGFloat
    public var isDark: Bool
    public var itemCount: Int
    /// Photos were under the bar, which was dark.
    public var isScrolledUnderBar: Bool
    public var accountEmail: String? = nil
  }

  public let image: CGImage
  public let info: Info
  let generation: Int

  static var currentGeneration: Int { lifecycle.withLock { $0 } }

  /// Starts reading the last snapshot, so it's ready for the first frame.
  public static func prefetch() {
    lifecycle.withLock { generation in
      let expected = generation
      pending.withLock { task in
        guard task == nil else { return }
        task = Task.detached(priority: .userInitiated) { read(generation: expected) }
      }
    }
  }

  /// The snapshot, once read; nil until then or when there's none.
  public static func load() async -> LibrarySnapshot? {
    if let ready { return ready }
    prefetch()
    guard let snapshot = await pending.withLock({ $0 })?.value, snapshot.generation == currentGeneration else { return nil }
    return snapshot
  }

  /// The snapshot if it has been read already, without waiting.
  public static var ready: LibrarySnapshot? { finished.withLock { $0 } }

  /// Writes the image and its details off the main thread. It's also kept in memory,
  /// for a window opened again while the app runs.
  public static func save(_ image: CGImage, info: Info) {
    save(image, info: info, generation: currentGeneration)
  }

  static func save(_ image: CGImage, info: Info, generation: Int) {
    let snapshot = LibrarySnapshot(image: image, info: info, generation: generation)
    // One write at a time; saves made meanwhile leave only the newest to write next.
    let startsWriter = lifecycle.withLock { current in
      guard current == generation, !held.withLock({ $0 }) else { return false }
      finished.withLock { $0 = snapshot }
      return queue.withLock { queue in
        queue.next = (snapshot, generation)
        defer { queue.isWriting = true }
        return !queue.isWriting
      }
    }
    guard startsWriter else { return }
    Task.detached(priority: .utility) {
      while let next = queue.withLock({ queue -> (snapshot: LibrarySnapshot, generation: Int)? in
        defer { queue.next = nil }
        if queue.next == nil { queue.isWriting = false }
        return queue.next
      }) {
        writing.withLock {
          guard lifecycle.withLock({ $0 == next.generation }) else { return }
          write(next.snapshot.image, info: next.snapshot.info)
        }
      }
    }
  }

  /// Writes the image and its details before returning, for an app about to quit.
  public static func saveNow(_ image: CGImage, info: Info) {
    saveNow(image, info: info, generation: currentGeneration)
  }

  static func saveNow(_ image: CGImage, info: Info, generation: Int) {
    writing.withLock {
      let canWrite = lifecycle.withLock { current in
        guard current == generation, !held.withLock({ $0 }) else { return false }
        // The async writer may already have dequeued an older capture.
        current &+= 1
        queue.withLock { $0.next = nil }
        pending.withLock { $0 = nil }
        let snapshot = LibrarySnapshot(image: image, info: info, generation: current)
        finished.withLock { $0 = snapshot }
        return true
      }
      if canWrite { write(image, info: info) }
    }
  }

  private static let lifecycle = OSAllocatedUnfairLock(initialState: 0)
  private static let queue = OSAllocatedUnfairLock(
    initialState: (next: Optional<(snapshot: LibrarySnapshot, generation: Int)>.none, isWriting: false))
  private static let writing = NSLock()

  #if os(macOS)
    /// PNG keeps the gaps between cells clear, over the window's own background.
    private static let imageType = UTType.png
  #else
    private static let imageType = UTType.jpeg
  #endif

  private static func write(_ image: CGImage, info: Info) {
    let bytes = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(bytes, imageType.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(destination), let metadata = try? JSONEncoder().encode(info) else { return }
    var length = UInt32(metadata.count).littleEndian
    var data = withUnsafeBytes(of: &length) { Data($0) }
    data.append(metadata)
    data.append(bytes as Data)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  /// Pauses captures during account transitions. Only the initial read can keep the previous screen.
  public static func holdSaves(_ holds: Bool, keepingSnapshot: Bool = false) {
    held.withLock { $0 = holds }
    if holds, !keepingSnapshot { remove() }
  }

  /// The initial account read may keep the previous screen, provided it still belongs to
  /// the selected account. Join only the read that launch already started.
  @MainActor
  static func validateLaunchAccount(_ email: String?) async {
    let snapshot: LibrarySnapshot?
    if let ready {
      snapshot = ready
    } else {
      snapshot = await pending.withLock({ $0 })?.value
    }
    guard let snapshot, snapshot.generation == currentGeneration else { return }
    if snapshot.info.accountEmail != email { remove() }
  }

  private static let held = OSAllocatedUnfairLock(initialState: false)

  public static func remove() {
    writing.withLock {
      lifecycle.withLock { generation in
        generation &+= 1
        queue.withLock { $0.next = nil }
        finished.withLock { $0 = nil }
        pending.withLock { $0 = nil }
        try? FileManager.default.removeItem(at: directory)
      }
    }
  }

  /// Retires captures and queued writes from before a Locked Folder transition.
  static func invalidate() { remove() }

  private static let pending = OSAllocatedUnfairLock<Task<LibrarySnapshot?, Never>?>(initialState: nil)
  private static let finished = OSAllocatedUnfairLock<LibrarySnapshot?>(initialState: nil)

  private static var directory: URL {
    var name = "LibrarySnapshot"
    #if DEBUG
      // Each review hook shows its own library.
      if let screen = UserDefaults.standard.string(forKey: "UIScreen") { name += "-" + screen }
    #endif
    return URL.cachesDirectory.appending(path: name)
  }
  private static var fileURL: URL { directory.appending(path: "grid.snapshot") }

  private static func read(generation: Int) -> LibrarySnapshot? {
    guard let data = try? Data(contentsOf: fileURL), data.count >= MemoryLayout<UInt32>.size else { return nil }
    let length = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
    let offset = MemoryLayout<UInt32>.size
    guard length <= data.count - offset,
      let info = try? JSONDecoder().decode(Info.self, from: data.subdata(in: offset..<(offset + length))),
      let source = CGImageSourceCreateWithData(data.subdata(in: (offset + length)..<data.count) as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(
        source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    else { return nil }
    let snapshot = LibrarySnapshot(image: image, info: info, generation: generation)
    // A snapshot saved since launch is newer than the one on disk.
    return lifecycle.withLock { current in
      guard current == generation else { return nil }
      return finished.withLock { saved in
        if saved == nil { saved = snapshot }
        return saved
      }
    }
  }
}
