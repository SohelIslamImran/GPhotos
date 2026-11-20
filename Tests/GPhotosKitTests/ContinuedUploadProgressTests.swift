import Foundation
import Testing

@testable import GPhotosKit

@Suite("Continued upload progress")
struct ContinuedUploadProgressTests {
  @Test("Real progress is reported as it is")
  func realProgress() {
    #expect(ContinuedUploadProgress.nextReported(after: 0, fraction: 0.5, totalItems: 4, heartbeat: false) == 2000)
  }

  @Test("A heartbeat moves stalled progress forward by one unit")
  func heartbeat() {
    #expect(ContinuedUploadProgress.nextReported(after: 2000, fraction: 0.5, totalItems: 4, heartbeat: true) == 2001)
  }

  @Test("Heartbeats never reach the end of the batch, and progress never goes back")
  func bounded() {
    #expect(ContinuedUploadProgress.nextReported(after: 3999, fraction: 0.9, totalItems: 4, heartbeat: true) == 3999)
    #expect(ContinuedUploadProgress.nextReported(after: 2500, fraction: 0.25, totalItems: 4, heartbeat: false) == 2500)
    #expect(ContinuedUploadProgress.nextReported(after: 3999, fraction: 1, totalItems: 4, heartbeat: false) == 4000)
  }

  @Test("The card's subtitle says what the batch is doing")
  func subtitle() {
    func line(_ seconds: TimeInterval?, paused: Bool = false, waiting: Bool = false, limited: Bool = false) -> String {
      ContinuedUploadProgress.subtitle(
        completed: 12, total: 340, secondsLeft: seconds, isPaused: paused, isWaitingForNetwork: waiting,
        isRateLimited: limited)
    }
    #expect(line(nil) == "12 of 340 backed up")
    #expect(line(30) == "12 of 340 backed up")
    #expect(line(61) == "12 of 340 backed up · about 2 min left")
    #expect(line(2 * 3600 + 600) == "12 of 340 backed up · about 2 h left")
    #expect(line(100, paused: true) == "Paused")
    #expect(line(100, waiting: true) == "Waiting for Wi\u{2011}Fi")
    #expect(line(100, limited: true) == "Waiting on Google Photos")
  }
}
