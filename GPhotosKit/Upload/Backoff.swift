import Foundation

public struct Backoff: Sendable {
  public let baseDelay: TimeInterval
  public let maxDelay: TimeInterval
  public let maxRetries: Int

  public init(baseDelay: TimeInterval = 1.0, maxDelay: TimeInterval = 30.0, maxRetries: Int = 3) {
    self.baseDelay = baseDelay
    self.maxDelay = maxDelay
    self.maxRetries = maxRetries
  }

  /// Exponential backoff with up to 25% random jitter, never exceeding `maxDelay`.
  public func delay(forAttempt attempt: Int) -> TimeInterval {
    let exponent = min(max(attempt, 0), 10)
    let capped = min(baseDelay * pow(2.0, Double(exponent)), maxDelay)
    return min(capped + Double.random(in: 0...capped * 0.25), maxDelay)
  }

  public func shouldRetry(attempt: Int) -> Bool {
    attempt < maxRetries
  }

  /// Whether an item that has failed `attempts` times, most recently at `lastAttempt`,
  /// may be tried again at `now`. Uses the un-jittered delay so the answer is stable.
  public func isReady(attempts: Int, lastAttempt: Date?, now: Date = Date()) -> Bool {
    guard shouldRetry(attempt: attempts) else { return false }
    guard let lastAttempt, attempts > 0 else { return true }
    let wait = min(baseDelay * pow(2.0, Double(min(attempts - 1, 10))), maxDelay)
    return now.timeIntervalSince(lastAttempt) >= wait
  }
}
