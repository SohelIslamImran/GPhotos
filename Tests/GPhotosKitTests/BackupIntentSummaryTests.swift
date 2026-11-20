import Foundation
import Testing

@testable import GPhotosKit

struct BackupIntentSummaryTests {
  @Test func noCompletedBackup() {
    #expect(
      BackupIntentSummary.text(pending: 3, uploading: 2, failed: 1, lastBackup: nil)
        == "3 pending, 2 uploading, 1 failed. No completed backup yet.")
  }

  @Test func lastVerifiedUpload() {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let summary = BackupIntentSummary.text(pending: 0, uploading: 0, failed: 0, lastBackup: date)
    #expect(summary.contains(date.formatted(date: .abbreviated, time: .shortened)))
    #expect(!summary.contains("No completed backup yet."))
  }
}
