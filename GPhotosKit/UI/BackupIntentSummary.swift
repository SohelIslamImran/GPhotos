import Foundation

/// Counts describe the current account, including the most recent verified upload.
public enum BackupIntentSummary {
  public static func text(pending: Int, uploading: Int, failed: Int, lastBackup: Date?) -> String {
    let counts = String(localized: "\(pending) pending, \(uploading) uploading, \(failed) failed.")
    guard let lastBackup else { return counts + " " + String(localized: "No completed backup yet.") }
    return counts + " " + String(localized: "Last backup: \(lastBackup.formatted(date: .abbreviated, time: .shortened)).")
  }
}
