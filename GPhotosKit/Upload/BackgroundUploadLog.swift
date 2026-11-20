import Foundation
import os

/// The photo upload extension runs on iOS's schedule with no debugger attached; its runs show
/// up in Console under this category.
public enum BackgroundUploadLog {
  private static let logger = Logger(subsystem: "org.gphotosapp.gphotos", category: "BackgroundUpload")

  public static func write(_ message: String) {
    logger.log("\(message, privacy: .public)")
    #if DEBUG
      append(message)
    #endif
  }

  #if DEBUG
    /// Debug builds also keep the lines in the App Group, where the app and the extension
    /// both write, so a run iOS made while nothing was attached can be read afterwards.
    public static var fileURL: URL {
      AppGroupConstants.storageDirectory().appendingPathComponent("background-upload.log")
    }

    private static let lock = NSLock()

    private static func append(_ message: String) {
      let line = "\(Date().formatted(.iso8601)) [\(ProcessInfo.processInfo.processName)] \(message)\n"
      lock.withLock {
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) { manager.createFile(atPath: fileURL.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size > 256 * 1024 {
          // Keeps the newer half.
          try? handle.close()
          if let data = try? Data(contentsOf: fileURL) { try? data.suffix(128 * 1024).write(to: fileURL) }
          guard let reopened = try? FileHandle(forWritingTo: fileURL) else { return }
          defer { try? reopened.close() }
          _ = try? reopened.seekToEnd()
          try? reopened.write(contentsOf: Data(line.utf8))
          return
        }
        try? handle.write(contentsOf: Data(line.utf8))
      }
    }
  #endif
}
