import Foundation

enum SuspensionGuard {
  /// Keeps iOS from suspending the process while `body` holds a lock on a file in a shared
  /// container, which ends the app (0xDEAD10CC).
  static func run<T>(_ body: () throws -> T) rethrows -> T {
    #if os(iOS)
      let answered = DispatchSemaphore(value: 0)
      let done = DispatchSemaphore(value: 0)
      ProcessInfo.processInfo.performExpiringActivity(withReason: "Save backup state") { expired in
        answered.signal()
        if !expired { done.wait() }
      }
      defer { done.signal() }
      // Already being suspended, it's never granted: the save goes ahead as it would have.
      _ = answered.wait(timeout: .now() + .milliseconds(100))
      return try body()
    #else
      return try body()
    #endif
  }
}
