import Foundation
import Testing

@testable import GPhotosKit

@Suite("MediaThumbnailLoader pure logic and AsyncSemaphore")
struct MediaThumbnailTests {
  @Test("Cache key reflects record id, pixel size, and modification date")
  func cacheKeyGeneration() {
    let date1 = Date(timeIntervalSince1970: 1_700_000_000)
    let date2 = Date(timeIntervalSince1970: 1_800_000_000)

    let recordWithAssetDate = TransferRecord(
      id: "acc|asset-123",
      filename: "photo.jpg",
      mediaType: "image/jpeg",
      status: .pending,
      assetLocalIdentifier: "asset-123",
      assetModifiedAt: date1
    )
    #expect(
      MediaThumbnailLoader.cacheKey(for: recordWithAssetDate, pixelSize: 80)
        == "acc|asset-123|80|1700000000"
    )

    // Falls back to sourceModifiedAt when assetModifiedAt is nil
    let recordWithSourceDate = TransferRecord(
      id: "acc|file-456",
      filename: "image.heic",
      mediaType: "image/heic",
      status: .pending,
      sourcePath: "/path/image.heic",
      sourceModifiedAt: date2
    )
    #expect(
      MediaThumbnailLoader.cacheKey(for: recordWithSourceDate, pixelSize: 64)
        == "acc|file-456|64|1800000000"
    )

    // Falls back to 0 when both are nil
    let recordWithNoDate = TransferRecord(
      id: "acc|nodate-789",
      filename: "file.png",
      mediaType: "image/png",
      status: .pending
    )
    #expect(
      MediaThumbnailLoader.cacheKey(for: recordWithNoDate, pixelSize: 120)
        == "acc|nodate-789|120|0"
    )

    // Distinct pixel size produces distinct key
    #expect(
      MediaThumbnailLoader.cacheKey(for: recordWithAssetDate, pixelSize: 40)
        != MediaThumbnailLoader.cacheKey(for: recordWithAssetDate, pixelSize: 80)
    )
  }

  @Test("Thumbnail cost is 4 bytes per pixel (RGBA)")
  func thumbnailCostCalculation() {
    #expect(MediaThumbnailLoader.cost(pixelWidth: 40, pixelHeight: 40) == 6_400)
    #expect(MediaThumbnailLoader.cost(pixelWidth: 80, pixelHeight: 80) == 25_600)
    #expect(MediaThumbnailLoader.cost(pixelWidth: 100, pixelHeight: 100) == 40_000)
    #expect(MediaThumbnailLoader.cost(pixelWidth: 0, pixelHeight: 0) == 0)
  }

  @Test("AsyncSemaphore enforces concurrency limit of permits")
  func asyncSemaphoreConcurrencyLimit() async {
    let semaphore = AsyncSemaphore(maxPermits: 4)
    #expect(await semaphore.availablePermits == 4)

    await semaphore.wait()
    #expect(await semaphore.availablePermits == 3)
    await semaphore.wait()
    #expect(await semaphore.availablePermits == 2)
    await semaphore.wait()
    #expect(await semaphore.availablePermits == 1)
    await semaphore.wait()
    #expect(await semaphore.availablePermits == 0)

    // 5th task must wait until a permit is signalled
    let fifthTaskStarted = ActorFlag()
    let fifthTaskCompleted = ActorFlag()

    let backgroundTask = Task {
      await fifthTaskStarted.set()
      await semaphore.withPermit {
        await fifthTaskCompleted.set()
      }
    }

    // Give the task a chance to start and enter wait()
    while !(await fifthTaskStarted.value) {
      await Task.yield()
    }
    // Yield several times to ensure it has reached the semaphore
    for _ in 0..<10 {
      await Task.yield()
    }
    #expect(await fifthTaskCompleted.value == false)
    #expect(await semaphore.availablePermits == 0)

    // Signal one permit; the fifth task should acquire it and finish
    await semaphore.signal()
    _ = await backgroundTask.value

    #expect(await fifthTaskCompleted.value == true)
    #expect(await semaphore.availablePermits == 1)

    // Signal the remaining 3 permits
    await semaphore.signal()
    await semaphore.signal()
    await semaphore.signal()
    #expect(await semaphore.availablePermits == 4)
  }

  @Test("TransferRecord mediaType helpers identify video, photo, and live photo")
  func transferRecordMediaHelpers() {
    let photo = TransferRecord(
      id: "1",
      filename: "photo.jpg",
      mediaType: "image/jpeg",
      status: .pending
    )
    #expect(!photo.isVideo)
    #expect(!photo.isLivePhoto)
    #expect(photo.mediaSymbol == "photo.fill")

    let video = TransferRecord(
      id: "2",
      filename: "clip.mov",
      mediaType: "video/quicktime",
      status: .pending
    )
    #expect(video.isVideo)
    #expect(!video.isLivePhoto)
    #expect(video.mediaSymbol == "video.fill")

    let livePhotoByType = TransferRecord(
      id: "3",
      filename: "live.heic",
      mediaType: "Live Photo",
      status: .pending
    )
    #expect(livePhotoByType.isLivePhoto)

    let livePhotoByPairedPath = TransferRecord(
      id: "4",
      filename: "live.heic",
      mediaType: "image/heic",
      status: .pending,
      pairedSourcePath: "/path/live.mov"
    )
    #expect(livePhotoByPairedPath.isLivePhoto)
  }
}

private actor ActorFlag {
  var value = false
  func set() { value = true }
}
