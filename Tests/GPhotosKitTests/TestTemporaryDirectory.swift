import Foundation
import XCTest

/// The test bundle's principal class. Tests keep their stores and files in `root`, one
/// folder for the run that is removed when the run finishes, so thousands of leftover
/// folders don't pile up in the system's temporary directory.
final class TestTemporaryDirectory: NSObject, XCTestObservation {
  private static let prefix = "GPhotosKitTestsRun-"

  static let root: URL = {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "\(prefix)\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  override init() {
    super.init()
    // Folders from earlier runs that crashed before they could clean up; a run still going
    // in another checkout keeps its own.
    let parent = FileManager.default.temporaryDirectory
    for name in (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
    where name.hasPrefix(Self.prefix) {
      guard let pid = Int32(name.dropFirst(Self.prefix.count)), pid != ProcessInfo.processInfo.processIdentifier,
        kill(pid, 0) != 0, errno == ESRCH
      else { continue }
      try? FileManager.default.removeItem(at: parent.appending(path: name))
    }
    XCTestObservationCenter.shared.addTestObserver(self)
  }

  func testBundleDidFinish(_ testBundle: Bundle) {
    try? FileManager.default.removeItem(at: Self.root)
  }
}
