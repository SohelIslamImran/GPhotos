import Foundation

/// Progress as iOS sees it for a continued upload. iOS ends a continued task whose progress
/// stops moving for about 30 seconds, and one item can take longer than that (a large video,
/// hashing, a rate-limit wait), so a heartbeat nudges the reported value forward without
/// letting it run ahead of the batch.
public enum ContinuedUploadProgress {
  public static let unitsPerItem: Int64 = 1000

  /// Next completed-unit value to report. Real progress (`fraction` of `totalItems`) jumps
  /// ahead; a heartbeat adds one unit but stays below the end of the batch.
  public static func nextReported(after reported: Int64, fraction: Double, totalItems: Int, heartbeat: Bool) -> Int64 {
    let total = max(1, Int64(totalItems)) * unitsPerItem
    let real = Int64((min(max(fraction, 0), 1) * Double(total)).rounded(.down))
    let next = max(reported, real) + (heartbeat ? 1 : 0)
    return min(next, max(real, total - 1))
  }

  /// The line under the title of iOS's progress card, which stands in for the Live Activity.
  /// Time left is whole minutes or hours, so the text does not change on every tick.
  public static func subtitle(
    completed: Int, total: Int, secondsLeft: TimeInterval?, isPaused: Bool, isOffline: Bool = false, isWaitingForNetwork: Bool,
    isRateLimited: Bool = false
  ) -> String {
    if isPaused { return String(localized: "Paused") }
    if isOffline { return String(localized: "Waiting for a connection") }
    if isWaitingForNetwork { return String(localized: "Waiting for Wi\u{2011}Fi") }
    if isRateLimited { return String(localized: "Waiting on Google Photos") }
    let count = "\(completed.formatted()) of \(total.formatted()) backed up"
    guard let secondsLeft, secondsLeft.isFinite, secondsLeft >= 60 else { return count }
    let minutes = Int((secondsLeft / 60).rounded(.up))
    let left = minutes < 60 ? "about \(minutes) min left" : "about \(Int((Double(minutes) / 60).rounded())) h left"
    return "\(count) · \(left)"
  }
}
