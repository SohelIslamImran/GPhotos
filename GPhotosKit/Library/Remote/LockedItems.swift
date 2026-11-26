import Foundation
import os

/// Which media keys each account's Locked Folder holds, checked wherever a Google Photos
/// image could be written to disk or requested. Keys are added before the sync that locks
/// them is committed, and dropped only once a committed page shows them unlocked.
enum LockedItems {
  static let didLock = Notification.Name("GooglePhotosItemsDidLock")
  private static let state = OSAllocatedUnfairLock<[String: Account]>(initialState: [:])

  private struct Account {
    let lifetime = UUID()
    var keys = Set<String>()
    /// The mirror's own list has been read, so a key not in `keys` isn't locked.
    var isKnown = false
  }

  static func contains(_ mediaKey: String, accountEmail: String) -> Bool {
    state.withLock { $0[accountEmail.lowercased()]?.keys.contains(mediaKey) == true }
  }

  static func containsInAnyAccount(_ mediaKey: String) -> Bool {
    state.withLock { $0.values.contains { $0.keys.contains(mediaKey) } }
  }

  /// False until the mirror has been read: what isn't known to be unlocked isn't kept.
  static func isKnownUnlocked(_ mediaKey: String, accountEmail: String) -> Bool {
    state.withLock { state in
      guard let account = state[accountEmail.lowercased()] else { return false }
      return account.isKnown && !account.keys.contains(mediaKey)
    }
  }

  static func unlockedLifetime(_ mediaKey: String, accountEmail: String) -> UUID? {
    state.withLock {
      guard let account = $0[accountEmail.lowercased()], account.isKnown, !account.keys.contains(mediaKey) else { return nil }
      return account.lifetime
    }
  }

  /// The write and the lock/removal notification cannot pass one another.
  static func withKnownState<T>(
    for accountEmail: String, _ work: (UUID, Set<String>) throws -> T
  ) rethrows -> T? {
    try state.withLockUnchecked {
      guard let account = $0[accountEmail.lowercased()], account.isKnown else { return nil }
      return try work(account.lifetime, account.keys)
    }
  }

  static func withKeys<T>(for accountEmail: String, _ work: (Set<String>) throws -> T) rethrows -> T {
    try state.withLockUnchecked { try work($0[accountEmail.lowercased()]?.keys ?? []) }
  }

  static func whileUnlocked(_ key: String, accountEmail: String?, _ work: () -> Void) {
    state.withLockUnchecked { accounts in
      let locked =
        if let accountEmail { accounts[accountEmail.lowercased()]?.keys.contains(key) == true } else {
          accounts.values.contains { $0.keys.contains(key) }
        }
      if !locked { work() }
    }
  }

  static func isKnown(accountEmail: String) -> Bool {
    state.withLock { $0[accountEmail.lowercased()]?.isKnown == true }
  }

  /// Those of `mediaKeys` in any account's Locked Folder, for the on-device index, which
  /// doesn't tell accounts apart.
  static func locked(among mediaKeys: Set<String>) -> Set<String> {
    state.withLock { state in
      state.values.reduce(into: Set()) { $0.formUnion(mediaKeys.intersection($1.keys)) }
    }
  }

  static func keys(accountEmail: String) -> Set<String> {
    state.withLock { $0[accountEmail.lowercased()]?.keys ?? [] }
  }

  /// The mirror's list, joined with what a sync added meanwhile.
  static func load(_ mediaKeys: Set<String>, accountEmail: String) {
    state.withLock {
      $0[accountEmail.lowercased(), default: Account()].keys.formUnion(mediaKeys)
      $0[accountEmail.lowercased(), default: Account()].isKnown = true
    }
  }

  static func insert(_ mediaKeys: Set<String>, accountEmail: String) {
    guard !mediaKeys.isEmpty else { return }
    state.withLock { $0[accountEmail.lowercased(), default: Account()].keys.formUnion(mediaKeys) }
    NotificationCenter.default.post(name: didLock, object: nil)
  }

  static func release(_ mediaKeys: Set<String>, accountEmail: String) {
    state.withLock { $0[accountEmail.lowercased()]?.keys.subtract(mediaKeys) }
  }

  /// The account was signed out or removed.
  static func forget(accountEmail: String) {
    state.withLock { $0[accountEmail.lowercased()] = nil }
  }
}

/// Removes what on-device analysis, Siri and Spotlight hold of items moved to the Locked
/// Folder, as they're moved and off the main actor. The mirror lists them until that's
/// done, so it's tried again after a failure, and at the next launch after a quit.
actor LockedIndexPurge {
  private let store: RemoteLibraryStore
  private let purge: @Sendable (Set<String>) async -> Bool
  private let retryDelay: Duration
  private var task: Task<Void, Never>?
  private var pause: Task<Void, Never>?
  private var isRequested = false
  private var isClosed = false
  private var needsStartupReconciliation = false

  init(
    store: RemoteLibraryStore, retryDelay: Duration = .seconds(5),
    purge: @escaping @Sendable (Set<String>) async -> Bool
  ) {
    self.store = store
    self.retryDelay = retryDelay
    self.purge = purge
  }

  @discardableResult
  func start(reconcileExisting: Bool = false) -> Task<Void, Never>? {
    guard !isClosed else { return nil }
    isRequested = true
    needsStartupReconciliation = needsStartupReconciliation || reconcileExisting
    pause?.cancel()
    if let task { return task }
    let task = Task(priority: .utility) { await run() }
    self.task = task
    return task
  }

  /// The library was switched away from or removed.
  func close() {
    isClosed = true
    pause?.cancel()
  }

  private func run() async {
    defer { task = nil }
    var delay = retryDelay
    while isRequested, !isClosed {
      isRequested = false
      do {
        if needsStartupReconciliation {
          try await store.enqueueExistingLockedKeys()
          needsStartupReconciliation = false
        }
        let keys = try await store.pendingLockedPurges()
        if keys.isEmpty { continue }
        if await purge(keys) {
          try await store.finishLockedPurges(keys)
          delay = retryDelay
          continue
        }
      } catch is RemoteLibraryStore.ClosedError {
        return
      } catch {}
      // One asked for meanwhile isn't kept waiting.
      if !isRequested, !isClosed {
        let wait = delay
        let pause = Task { () -> Void in try? await Task.sleep(for: wait) }
        self.pause = pause
        await pause.value
        delay = min(delay * 2, .seconds(10 * 60))
      }
      isRequested = true
    }
  }
}
