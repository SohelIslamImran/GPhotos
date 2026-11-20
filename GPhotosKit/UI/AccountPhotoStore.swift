import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Observation

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

struct AccountPhotoRefresh: Sendable {
  static let maxAge: TimeInterval = 30 * 24 * 60 * 60
  var refreshedAt: Date?
  var retryAt: Date?
  var failures = 0

  func isDue(at now: Date) -> Bool {
    if let retryAt, now < retryAt { return false }
    guard let refreshedAt else { return true }
    let age = now.timeIntervalSince(refreshedAt)
    return age < 0 || age >= Self.maxAge
  }

  mutating func failed(at now: Date) {
    failures = min(failures + 1, 10)
    retryAt = now.addingTimeInterval(min(60 * pow(2, Double(failures - 1)), 6 * 60 * 60))
  }
}

/// Google profile photos, shown from disk while a missing or month-old photo refreshes.
@MainActor
@Observable
public final class AccountPhotoStore {
  public static let shared = AccountPhotoStore()

  public private(set) var photos: [String: CGImage] = [:]
  @ObservationIgnored private var accounts: [String: GoogleAccount] = [:]
  @ObservationIgnored private var refresh: [String: AccountPhotoRefresh] = [:]
  @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var retryTask: Task<Void, Never>?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private let cache = AccountPhotoCache()

  private init() {
    let center = NotificationCenter.default
    #if os(iOS)
      let foreground = UIApplication.didBecomeActiveNotification
    #else
      let foreground = NSApplication.didBecomeActiveNotification
    #endif
    for name in [foreground, NetworkStatusMonitor.didReconnect] {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in self?.refreshPhotos() }
      }
    }
  }

  nonisolated static func emailKey(_ email: String) -> String {
    email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  public func photo(for email: String) -> CGImage? {
    photos[Self.emailKey(email)]
  }

  public func update(for accounts: [GoogleAccount]) {
    var next: [String: GoogleAccount] = [:]
    for account in accounts {
      let key = Self.emailKey(account.email)
      if !key.isEmpty { next[key] = account }
    }
    if next != self.accounts || generation == 0 {
      generation += 1
      for task in tasks.values { task.cancel() }
      tasks = [:]
      refresh = refresh.filter { next[$0.key]?.credentialString == self.accounts[$0.key]?.credentialString }
      self.accounts = next
      photos = photos.filter { next[$0.key] != nil }
      let generation = generation
      let emails = Set(next.keys)
      Task { await cache.keep(emails, generation: generation) }
    }
    refreshPhotos()
  }

  private func refreshPhotos() {
    for (email, account) in accounts where tasks[email] == nil {
      guard (refresh[email] ?? AccountPhotoRefresh()).isDue(at: .now) else { continue }
      let generation = generation
      let emails = Set(accounts.keys)
      tasks[email] = Task {
        await cache.keep(emails, generation: generation)
        let cached = await cache.load(email)
        guard !Task.isCancelled, self.generation == generation else { return }
        if let cached {
          photos[email] = cached.image
          refresh[email, default: AccountPhotoRefresh()].refreshedAt = cached.date
        }
        guard (refresh[email] ?? AccountPhotoRefresh()).isDue(at: .now) else {
          refresh[email]?.retryAt = nil
          tasks[email] = nil
          scheduleRetry()
          return
        }
        if NetworkStatusMonitor.shared.isConnected {
          let data = await Self.fetchPhoto(credential: account.credentialString)
          guard !Task.isCancelled, self.generation == generation else { return }
          if let data, let image = Self.decode(data) {
            photos[email] = image
            refresh[email] = AccountPhotoRefresh(refreshedAt: .now)
            await cache.store(data, for: email, generation: generation)
          } else {
            refresh[email, default: AccountPhotoRefresh()].failed(at: .now)
          }
        } else {
          refresh[email, default: AccountPhotoRefresh()].failed(at: .now)
        }
        guard self.generation == generation else { return }
        tasks[email] = nil
        scheduleRetry()
      }
    }
    scheduleRetry()
  }

  private func scheduleRetry() {
    retryTask?.cancel()
    guard let next = refresh.filter({ tasks[$0.key] == nil }).values.compactMap(\.retryAt).min() else { return }
    retryTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow))) } catch { return }
      self?.refreshPhotos()
    }
  }

  nonisolated private static func fetchPhoto(credential: String) async -> Data? {
    let auth = GoogleAuthService()
    do {
      try await auth.setCredential(credential)
      return try await auth.profilePhoto(pixelSize: 192)
    } catch {
      return nil
    }
  }

  nonisolated static func decode(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }
}

/// Serializes pruning and writes; an old account refresh cannot restore a removed file.
actor AccountPhotoCache {
  private let directory: URL
  private var generation = -1
  private var emails: Set<String> = []

  init(directory: URL = URL.cachesDirectory.appending(path: "AccountPhotos", directoryHint: .isDirectory)) {
    self.directory = directory
  }

  private func url(_ email: String) -> URL {
    let name = SHA256.hash(data: Data(AccountPhotoStore.emailKey(email).utf8))
      .map { String(format: "%02x", $0) }.joined()
    return directory.appending(path: name)
  }

  func keep(_ emails: Set<String>, generation: Int) {
    guard generation >= self.generation else { return }
    self.generation = generation
    self.emails = emails
    let kept = Set(emails.map { url($0).lastPathComponent })
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    for file in files where !kept.contains(file.lastPathComponent) {
      try? FileManager.default.removeItem(at: file)
    }
  }

  func load(_ email: String) -> (image: CGImage, date: Date)? {
    let file = url(email)
    guard let data = try? Data(contentsOf: file), let image = AccountPhotoStore.decode(data),
      let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    else { return nil }
    return (image, date)
  }

  func store(_ data: Data, for email: String, generation: Int) {
    guard generation == self.generation, emails.contains(email) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: url(email), options: .atomic)
  }
}
