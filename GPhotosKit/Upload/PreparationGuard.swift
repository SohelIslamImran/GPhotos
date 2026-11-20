import Foundation

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

/// Stops one item from taking down every backup. An item that ends the process while it is
/// exported or hashed (a huge video exhausting memory, say) would otherwise be
/// picked again on every relaunch. Items in flight carry a marker; a marker found at launch
/// counts as an interruption, and an item interrupted `limit` times is skipped for a day.
///
/// On iOS, markers are kept only while the app is active. Once it leaves the screen, the
/// user can swipe it away or iOS can end it at any moment, and neither says anything about
/// the item.
public final class PreparationGuard: @unchecked Sendable {
  public static let shared = PreparationGuard(defaults: .standard)
  static let limit = 2
  static let skipInterval: TimeInterval = 24 * 60 * 60
  public static let skippedMessage =
    "GPhotos closed twice while backing this item up, so it will be tried again in a day."

  private static let markersKey = "preparationGuard.markers"
  private static let countsKey = "preparationGuard.interruptions"
  private static let skippedKey = "preparationGuard.skippedAt"

  private let defaults: UserDefaults
  private let lock = NSLock()
  private var observesExits = false
  /// Items being prepared, kept in memory so their markers can be written again when the
  /// app comes back on screen.
  private var inFlight: [String] = []
  private var recordsMarkers = true

  /// Reads what the previous process left behind, so it runs before this process marks
  /// anything of its own.
  init(defaults: UserDefaults, now: Date = Date()) {
    self.defaults = defaults
    let leftover = defaults.stringArray(forKey: Self.markersKey) ?? []
    guard !leftover.isEmpty else { return }
    var counts = defaults.dictionary(forKey: Self.countsKey) as? [String: Int] ?? [:]
    var skipped = defaults.dictionary(forKey: Self.skippedKey) as? [String: Date] ?? [:]
    for id in leftover {
      let count = (counts[id] ?? 0) + 1
      counts[id] = count
      if count >= Self.limit { skipped[id] = now }
    }
    defaults.set(counts, forKey: Self.countsKey)
    defaults.set(skipped, forKey: Self.skippedKey)
    defaults.removeObject(forKey: Self.markersKey)
  }

  /// A quit the system announces is not an item taking the process down, so the markers of
  /// whatever was in flight are dropped. On iOS the same goes for any time off screen.
  @MainActor
  public func observeCleanExits() {
    let isFirst = lock.withLock {
      defer { observesExits = true }
      return !observesExits
    }
    guard isFirst else { return }
    let center = NotificationCenter.default
    #if os(iOS)
      setRecordsMarkers(UIApplication.shared.applicationState == .active)
      center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) {
        [weak self] _ in
        self?.setRecordsMarkers(true)
      }
      center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) {
        [weak self] _ in
        self?.setRecordsMarkers(false)
      }
      let name = UIApplication.willTerminateNotification
    #elseif os(macOS)
      let name = NSApplication.willTerminateNotification
    #endif
    #if os(iOS) || os(macOS)
      center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
        self?.forgetInFlight()
      }
    #endif
  }

  /// Whether a process ending now would count against the items in flight.
  func setRecordsMarkers(_ records: Bool) {
    lock.withLock {
      recordsMarkers = records
      if records {
        defaults.set(inFlight, forKey: Self.markersKey)
      } else {
        defaults.removeObject(forKey: Self.markersKey)
      }
    }
  }

  public func forgetInFlight() {
    lock.withLock { defaults.removeObject(forKey: Self.markersKey) }
  }

  /// Whether the item is being skipped. A skip that has run its course is forgotten, giving
  /// the item a fresh start.
  public func isSkipped(_ id: String, now: Date = Date()) -> Bool {
    lock.withLock {
      var skipped = defaults.dictionary(forKey: Self.skippedKey) as? [String: Date] ?? [:]
      guard let since = skipped[id] else { return false }
      if now.timeIntervalSince(since) < Self.skipInterval { return true }
      skipped[id] = nil
      defaults.set(skipped, forKey: Self.skippedKey)
      var counts = defaults.dictionary(forKey: Self.countsKey) as? [String: Int] ?? [:]
      counts[id] = nil
      defaults.set(counts, forKey: Self.countsKey)
      return false
    }
  }

  /// The user asked for the item again, which ends its skip.
  public func forgive(_ id: String) {
    lock.withLock {
      var skipped = defaults.dictionary(forKey: Self.skippedKey) as? [String: Date] ?? [:]
      skipped[id] = nil
      defaults.set(skipped, forKey: Self.skippedKey)
      var counts = defaults.dictionary(forKey: Self.countsKey) as? [String: Int] ?? [:]
      counts[id] = nil
      defaults.set(counts, forKey: Self.countsKey)
    }
  }

  /// Whether the item was in flight when the process last died and has not finished since.
  public func isSuspect(_ id: String) -> Bool {
    lock.withLock { (defaults.dictionary(forKey: Self.countsKey) as? [String: Int])?[id] != nil }
  }

  public func begin(_ id: String) {
    lock.withLock {
      guard !inFlight.contains(id) else { return }
      inFlight.append(id)
      if recordsMarkers { defaults.set(inFlight, forKey: Self.markersKey) }
    }
  }

  /// The item came back, in any outcome, so nothing about it takes the process down.
  public func end(_ id: String) {
    lock.withLock {
      if let index = inFlight.firstIndex(of: id) {
        inFlight.remove(at: index)
        if recordsMarkers { defaults.set(inFlight, forKey: Self.markersKey) }
      }
      var counts = defaults.dictionary(forKey: Self.countsKey) as? [String: Int] ?? [:]
      if counts.removeValue(forKey: id) != nil {
        defaults.set(counts, forKey: Self.countsKey)
      }
    }
  }
}
