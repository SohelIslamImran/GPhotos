import Foundation
import Testing
import UserNotifications

@testable import GPhotosKit

@Suite("Notification and Live Activity Logic Tests")
struct NotificationAndLiveActivityTests {

  // MARK: - Notification Coalescer: Batch Event Selection

  @Test("Auth failure takes precedence over any successes or failures")
  func testAuthFailurePrecedence() {
    let event = NotificationCoalescer.eventForBatch(
      uploadedCount: 100,
      failedCount: 5,
      authErrorEmail: "alice@gmail.com",
      isAppFrontmost: false
    )
    #expect(event == .accountNeedsSignIn(email: "alice@gmail.com"))
  }

  @Test("Failures take precedence over successful uploads")
  func testFailurePrecedence() {
    let event = NotificationCoalescer.eventForBatch(
      uploadedCount: 50,
      failedCount: 12,
      authErrorEmail: nil,
      isAppFrontmost: false
    )
    #expect(event == .batchFailed(uploaded: 50, failed: 12))
  }

  @Test("Success event emitted when uploaded count is at least 1 and no failures")
  func testSuccessEvent() {
    let event = NotificationCoalescer.eventForBatch(
      uploadedCount: 1234,
      failedCount: 0,
      authErrorEmail: nil,
      isAppFrontmost: false
    )
    #expect(event == .backupFinished(count: 1234))
  }

  @Test("No event emitted when batch uploaded 0 items and had 0 failures")
  func testEmptyBatchNoEvent() {
    let event = NotificationCoalescer.eventForBatch(
      uploadedCount: 0,
      failedCount: 0,
      authErrorEmail: nil,
      isAppFrontmost: false
    )
    #expect(event == nil)
  }

  // MARK: - Notification Coalescer: Frontmost Filtering

  @Test("Notifications are suppressed when app is frontmost")
  func testFrontmostSuppression() {
    let suppressed = NotificationCoalescer.eventForBatch(
      uploadedCount: 10,
      failedCount: 0,
      authErrorEmail: nil,
      isAppFrontmost: true
    )
    #expect(suppressed == nil)
  }

  // MARK: - Notification Content & Formatting

  @Test("Backup finished copy formatting")
  func testBackupFinishedFormatting() {
    let single = NotificationCoalescer.content(for: .backupFinished(count: 1))
    #expect(single.title == "Backup Complete")
    #expect(single.body == "1 item backed up to Google Photos.")
    #expect(single.interruptionLevel == .passive)

    let plural = NotificationCoalescer.content(for: .backupFinished(count: 1234))
    #expect(plural.title == "Backup Complete")
    #expect(plural.body == "1,234 items backed up to Google Photos.")
    #expect(plural.interruptionLevel == .passive)
    #expect(plural.categoryIdentifier == BackupNotifier.backupFinishedCategoryIdentifier)
  }

  @Test("Batch failures copy formatting and retry action setup")
  func testBatchFailuresFormatting() {
    let single = NotificationCoalescer.content(for: .batchFailed(uploaded: 0, failed: 1))
    #expect(single.title == "Some Items Didn't Upload")
    #expect(single.body == "1 item failed. Open GPhotos to retry.")
    #expect(single.interruptionLevel == .active)
    #expect(single.categoryIdentifier == BackupNotifier.failedCategoryIdentifier)
    #expect(single.destination == BackupNotifier.destinationFailed)

    let plural = NotificationCoalescer.content(for: .batchFailed(uploaded: 2, failed: 12))
    #expect(plural.title == "Some Items Didn't Upload")
    #expect(plural.body == "2 items backed up to Google Photos. 12 items failed. Open GPhotos to retry.")
    #expect(plural.interruptionLevel == .active)
    #expect(plural.destination == BackupNotifier.destinationFailed)
  }

  @Test("Account needs sign-in copy formatting")
  func testAccountNeedsSignInFormatting() {
    let content = NotificationCoalescer.content(for: .accountNeedsSignIn(email: "user@example.com"))
    #expect(content.title == "Sign In Again")
    #expect(content.body == "user@example.com needs you to sign in again to keep backing up.")
    #expect(content.interruptionLevel == .active)
    #expect(content.categoryIdentifier == BackupNotifier.accountAuthCategoryIdentifier)
    #expect(content.destination == BackupNotifier.destinationAccount)
  }

  @Test("Secondary copy finished copy formatting")
  func testSecondaryCopyFinishedFormatting() {
    let single = NotificationCoalescer.content(
      for: .secondaryCopiesUpdated(count: 1, email: "backup@example.com")
    )
    #expect(single.title == "Copies Updated")
    #expect(single.body == "1 item copied to backup@example.com.")
    #expect(single.interruptionLevel == .passive)
    #expect(single.categoryIdentifier == BackupNotifier.secondaryCopyCategoryIdentifier)

    let plural = NotificationCoalescer.content(
      for: .secondaryCopiesUpdated(count: 42, email: "backup@example.com")
    )
    #expect(plural.title == "Copies Updated")
    #expect(plural.body == "42 items copied to backup@example.com.")
    #expect(plural.interruptionLevel == .passive)
  }

  @Test("Fast progress still shares a one-second update interval")
  func activityUpdateRate() {
    #expect(!LiveActivityThrottle.shouldUpdate(elapsed: .milliseconds(999), stateChanged: true))
    #expect(LiveActivityThrottle.shouldUpdate(elapsed: .seconds(1), stateChanged: true))
  }

  @Test("Unchanged activity content only refreshes its stale date")
  func activityHeartbeat() {
    #expect(!LiveActivityThrottle.shouldUpdate(elapsed: .seconds(29), stateChanged: false))
    #expect(LiveActivityThrottle.shouldUpdate(elapsed: .seconds(30), stateChanged: false))
  }

  @Test("A stopped or partial batch cannot finish as complete")
  func activityOutcome() {
    #expect(BackupActivityOutcome(completed: 4, total: 4, stopped: false) == .complete)
    #expect(BackupActivityOutcome(completed: 3, total: 4, stopped: false) == .incomplete)
    #expect(BackupActivityOutcome(completed: 4, total: 4, stopped: true) == .stopped)
    #expect(BackupActivityOutcome(completed: 0, total: 0, stopped: false) == .incomplete)
  }
}
