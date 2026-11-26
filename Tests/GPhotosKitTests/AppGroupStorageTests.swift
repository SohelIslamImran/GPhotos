import Foundation
import Testing

@testable import GPhotosKit

@Suite("App Group storage")
struct AppGroupStorageTests {
  @Test("A full disk doesn't count as an unreachable container")
  func fullDisk() {
    let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    #expect(AppGroupConstants.isOutOfSpace(posix))
    #expect(AppGroupConstants.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)))
    #expect(
      AppGroupConstants.isOutOfSpace(
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: posix])))
    #expect(!AppGroupConstants.isOutOfSpace(CocoaError(.fileWriteNoPermission)))
  }
}
