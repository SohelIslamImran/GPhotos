import Foundation

/// Remembers the Google Photos album created for each album name, per account, so later
/// batches add to the existing album instead of creating another one with the same title.
/// Also tracks the item count per album to respect Google Photos' 20,000-item limit.
///
/// Without this, every batch containing a new photo in "Family" would create another
/// album called "Family".
public final class AlbumKeyStore: @unchecked Sendable {
  public static let shared = AlbumKeyStore(
    fileURL: AppGroupConstants.storageDirectory().appendingPathComponent("album-keys.json"))

  private struct Storage: Codable {
    var keys: [String: [String: String]] = [:]
    var counts: [String: [String: Int]] = [:]
  }

  private let fileURL: URL
  private let lock = NSLock()
  /// Per account email: album name to album media key, and album name to item count.
  /// Loaded once, then served from memory.
  private var cache: Storage?

  init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func key(forAlbumNamed name: String, accountEmail: String) -> String? {
    lock.withLock { loadedUnlocked().keys[accountEmail]?[name] }
  }

  /// Records the album created for `name`. The first key wins, because reusing the
  /// album the user already has matters more than tracking a newer one.
  public func remember(key: String, forAlbumNamed name: String, accountEmail: String) {
    lock.withLock {
      var storage = loadedUnlocked()
      guard storage.keys[accountEmail]?[name] == nil else { return }
      storage.keys[accountEmail, default: [:]][name] = key
      saveUnlocked(storage)
    }
  }

  /// Current item count tracked for the given album and account.
  public func count(forAlbumNamed name: String, accountEmail: String) -> Int {
    lock.withLock { loadedUnlocked().counts[accountEmail]?[name] ?? 0 }
  }

  /// Sets the tracked item count for `name`.
  public func setCount(_ count: Int, forAlbumNamed name: String, accountEmail: String) {
    lock.withLock {
      var storage = loadedUnlocked()
      storage.counts[accountEmail, default: [:]][name] = count
      saveUnlocked(storage)
    }
  }

  /// Increments the tracked item count for `name`.
  public func incrementCount(by amount: Int, forAlbumNamed name: String, accountEmail: String) {
    guard amount > 0 else { return }
    lock.withLock {
      var storage = loadedUnlocked()
      let current = storage.counts[accountEmail]?[name] ?? 0
      storage.counts[accountEmail, default: [:]][name] = current + amount
      saveUnlocked(storage)
    }
  }

  /// Drops a key the server no longer accepts, so the next batch creates the album again.
  public func forget(albumNamed name: String, accountEmail: String) {
    lock.withLock {
      var storage = loadedUnlocked()
      let removedKey = storage.keys[accountEmail]?.removeValue(forKey: name)
      let removedCount = storage.counts[accountEmail]?.removeValue(forKey: name)
      guard removedKey != nil || removedCount != nil else { return }
      if storage.keys[accountEmail]?.isEmpty == true { storage.keys.removeValue(forKey: accountEmail) }
      if storage.counts[accountEmail]?.isEmpty == true { storage.counts.removeValue(forKey: accountEmail) }
      saveUnlocked(storage)
    }
  }

  /// Drops all keys and tracked counts for the given account.
  public func forgetAll(forAccountEmail accountEmail: String) {
    lock.withLock {
      var storage = loadedUnlocked()
      let removedKeys = storage.keys.removeValue(forKey: accountEmail)
      let removedCounts = storage.counts.removeValue(forKey: accountEmail)
      guard removedKeys != nil || removedCounts != nil else { return }
      saveUnlocked(storage)
    }
  }

  private func loadedUnlocked() -> Storage {
    if let cache { return cache }
    if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
      cache = decoded
      return decoded
    }
    let storage = Storage()
    cache = storage
    return storage
  }

  private func saveUnlocked(_ storage: Storage) {
    cache = storage
    // Best effort: losing this map costs a duplicate album, not lost photos.
    guard let data = try? JSONEncoder().encode(storage) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
