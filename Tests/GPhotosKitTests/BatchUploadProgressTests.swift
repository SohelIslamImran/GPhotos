import Testing

@testable import GPhotosKit

@Suite("Batch upload progress")
struct BatchUploadProgressTests {
  @Test("Concurrent files are weighted by bytes, retries never double count, and commit gates completion")
  func concurrentRetries() {
    var progress = BatchUploadProgress()
    progress.include(id: "a", size: 100)
    progress.include(id: "b", size: 900)
    progress.sent(id: "a", bytes: 0, at: 0)
    progress.sent(id: "a", bytes: 100, at: 1)
    progress.sent(id: "b", bytes: 400, at: 1)
    #expect(progress.fraction == 0.5)
    progress.sent(id: "b", bytes: 50, at: 2)
    #expect(progress.transferredBytes == 500)
    progress.complete(id: "a")
    #expect(progress.transferredBytes == 500)
    progress.sent(id: "b", bytes: 900, at: 3)
    #expect(progress.fraction == 0.99)
    progress.complete(id: "b")
    #expect(progress.fraction == 1)
  }

  @Test("Dedup and changing source sizes affect batch work but do not invent network speed")
  func sizesAndDedup() {
    var progress = BatchUploadProgress()
    progress.include(id: "live", size: 100)
    progress.resize(id: "live", size: 500)
    progress.complete(id: "live")
    progress.include(id: "new", size: 500)
    #expect(progress.totalBytes == 1000)
    #expect(progress.backedUpBytes == 500)
    #expect(progress.fraction == 0.5)
    #expect(progress.speed(at: 10) == nil)
    progress.include(id: "new", size: 999)
    #expect(progress.totalBytes == 1000)
  }

  @Test("Rate requires a time window, smooths over five seconds and expires on stalls")
  func speedWindow() {
    var progress = BatchUploadProgress()
    progress.include(id: "a", size: 10000)
    progress.sent(id: "a", bytes: 0, at: 0)
    progress.sent(id: "a", bytes: 1000, at: 0.1)
    #expect(progress.speed(at: 0.1) == nil)
    progress.sent(id: "a", bytes: 2000, at: 2)
    #expect(progress.speed(at: 2) == 1000)
    progress.sample(at: 5)
    #expect(progress.speed(at: 5) == nil)
  }

  @Test("An existing Live Photo still contributes no traffic when only its motion uploads")
  func existingComponent() {
    var progress = BatchUploadProgress()
    progress.include(id: "live", size: 1000)
    progress.sent(id: "live", bytes: 0, at: 0)
    progress.creditExisting(id: "live", bytes: 800)
    progress.sent(id: "live", bytes: 900, at: 1)
    #expect(progress.transferredBytes == 900)
    #expect(progress.speed(at: 1) == 100)
    #expect(progress.backedUpBytes == 0)
  }

  @Test("Zero byte items and empty batches require completion")
  func emptySizes() {
    var progress = BatchUploadProgress()
    #expect(progress.fraction == 0)
    progress.include(id: "a", size: 0)
    #expect(progress.fraction == 0)
    progress.complete(id: "a")
    #expect(progress.fraction == 1)
  }

  @Test("Running totals stay right through resizes, retried bytes and repeated completions")
  func runningTotals() {
    var progress = BatchUploadProgress()
    progress.include(id: "a", size: 100)
    progress.sent(id: "a", bytes: 80, at: 0)
    progress.resize(id: "a", size: 50)
    #expect(progress.totalBytes == 50)
    #expect(progress.transferredBytes == 50)
    progress.creditExisting(id: "a", bytes: 10)
    #expect(progress.transferredBytes == 50)
    progress.include(id: "b", size: 50)
    progress.complete(id: "a")
    progress.complete(id: "a")
    #expect(progress.backedUpBytes == 50)
    #expect(progress.transferredBytes == 50)
    #expect(progress.fraction == 0.5)
    progress.complete(id: "b")
    #expect(progress.fraction == 1)
  }
}
