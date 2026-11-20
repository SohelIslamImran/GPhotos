import Foundation
import Testing

@testable import GPhotosKit

@Suite("App Group storage and watched-folder rules")
struct AppGroupAndShareTests {
  private func temporaryFile(_ name: String) -> URL {
    let directory = TestTemporaryDirectory.root
      .appendingPathComponent("AppGroupAndShareTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(name)
  }

  @Test("A corrupt share queue is quarantined and reads as empty")
  func corruptQueueIsQuarantined() throws {
    let url = temporaryFile("pending-uploads.json")
    try Data("not json".utf8).write(to: url)

    #expect(try SharedQueueBridge.readQueue(at: url).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    let backup = url.appendingPathExtension("unreadable")
    #expect(try Data(contentsOf: backup) == Data("not json".utf8))
  }

  @Test("A valid share queue round-trips without being quarantined")
  func validQueueIsRead() throws {
    let url = temporaryFile("pending-uploads.json")
    let entry = SharedUploadEntry(fileName: "a.jpg", relativePath: "a.jpg", bytesTotal: 1, sha1Base64: "x")
    try JSONEncoder().encode([entry]).write(to: url)

    #expect(try SharedQueueBridge.readQueue(at: url) == [entry])
    #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable").path))
  }

  @Test("Settings that fail to decode are quarantined")
  func corruptSettingsAreQuarantined() throws {
    let url = temporaryFile("app-settings.json")
    try Data("{".utf8).write(to: url)

    #expect(AppSettingsStore.load(from: url) == AppSettings())
    #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable").path))
  }

  @Test("Settings that cannot be read are left in place")
  func unreadableSettingsAreKept() throws {
    // A directory at the settings path makes the read fail without a decode error.
    let url = temporaryFile("app-settings.json")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

    #expect(AppSettingsStore.load(from: url) == AppSettings())
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable").path))
  }

  @Test("Folder containment ignores case and trailing slashes")
  func folderContainment() {
    #expect(WatchedFolderPaths.isPath("/Users/me/Pictures", inside: "/Users/me/Pictures/"))
    #expect(WatchedFolderPaths.isPath("/users/ME/pictures/Trip/a.jpg", inside: "/Users/me/Pictures"))
    #expect(!WatchedFolderPaths.isPath("/Users/me/Pictures Old/a.jpg", inside: "/Users/me/Pictures"))
    #expect(!WatchedFolderPaths.isPath("/Users/me", inside: "/Users/me/Pictures"))
  }

  @Test("Only media changes outside hidden items and packages trigger a rescan")
  func watcherEventFilter() {
    let root = "/Users/me/Pictures"
    func relevant(_ path: String, isFile: Bool = true) -> Bool {
      WatchedFolderPaths.isRelevantChange(path: path, root: root, isFile: isFile)
    }
    #expect(relevant("/Users/me/Pictures/Trip/IMG_0001.HEIC"))
    #expect(relevant("/Users/me/Pictures/Trip/clip.mov"))
    #expect(relevant("/Users/me/Pictures/New Album", isFile: false))
    #expect(relevant(root, isFile: false))

    #expect(!relevant("/Users/me/Pictures/.DS_Store"))
    #expect(!relevant("/Users/me/Pictures/Trip/.gphotos-delete-abc-1-2-IMG_0001.HEIC"))
    #expect(!relevant("/Users/me/Pictures/.hidden/IMG_0002.jpg"))
    #expect(!relevant("/Users/me/Pictures/Photos Library.photoslibrary/originals/A/IMG.jpg"))
    #expect(!relevant("/Users/me/Pictures/Photos Library.photoslibrary/database", isFile: false))
    #expect(!relevant("/Users/me/Pictures/Trip/IMG_0003.jpg.partial"))
    #expect(!relevant("/Users/me/Pictures/notes.txt"))
  }
}
