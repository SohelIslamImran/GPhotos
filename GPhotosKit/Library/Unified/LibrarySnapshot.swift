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
  }

  public let image: CGImage
  public let info: Info

  /// Starts reading the last snapshot, so it's ready for the first frame.
  public static func prefetch() {
    let generation = lifecycle.withLock { $0 }
    pending.withLock { task in
      guard task == nil else { return }
      task = Task.detached(priority: .userInitiated) { read(generation: generation) }
    }
  }

  /// The snapshot, once read; nil until then or when there's none.
  public static func load() async -> LibrarySnapshot? {
    if let ready { return ready }
    prefetch()
    return await pending.withLock { $0 }?.value
  }

  /// The snapshot if it has been read already, without waiting.
  public static var ready: LibrarySnapshot? { finished.withLock { $0 } }

  /// Writes the image and its details off the main thread. It's also kept in memory,
  /// for a window opened again while the app runs.
  public static func save(_ image: CGImage, info: Info) {
    let snapshot = LibrarySnapshot(image: image, info: info)
    // One write at a time; saves made meanwhile leave only the newest to write next.
    let startsWriter = lifecycle.withLock { generation in
      let generation = generation
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
    writing.withLock {
      invalidate(replacingWith: LibrarySnapshot(image: image, info: info))
      write(image, info: info)
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
    let manager = FileManager.default
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    guard
      let destination = CGImageDestinationCreateWithURL(
        imageURL as CFURL, imageType.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(destination), let data = try? JSONEncoder().encode(info) else {
      try? manager.removeItem(at: directory)
      return
    }
    try? data.write(to: infoURL, options: .atomic)
  }

  /// Forgets the snapshot (an account's photos were removed).
  public static func remove() {
    writing.withLock {
      invalidate()
      try? FileManager.default.removeItem(at: directory)
    }
  }

  /// Invalidate work that has already been dequeued as well as work still waiting.
  private static func invalidate(replacingWith snapshot: LibrarySnapshot? = nil) {
    lifecycle.withLock { generation in
      generation &+= 1
      queue.withLock { $0.next = nil }
      finished.withLock { $0 = snapshot }
    }
    pending.withLock { $0 = nil }
  }

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
  private static var imageURL: URL { directory.appending(path: "grid").appendingPathExtension(for: imageType) }
  private static var infoURL: URL { directory.appending(path: "info.json") }

  private static func read(generation: Int) -> LibrarySnapshot? {
    guard let data = try? Data(contentsOf: infoURL), let info = try? JSONDecoder().decode(Info.self, from: data),
      let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
      // Decoded here, not on the main thread as it's first drawn.
      let image = CGImageSourceCreateImageAtIndex(
        source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    else { return nil }
    let snapshot = LibrarySnapshot(image: image, info: info)
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
