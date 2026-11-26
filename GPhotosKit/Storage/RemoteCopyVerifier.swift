import Foundation

/// Asks Google Photos, right before a cleanup, whether each uploaded item is still in the
/// account. The manifest only proves an upload happened; the user may have deleted the
/// copy from Google Photos since. Anything that can't be confirmed, including every
/// network or decoding error, is held back.
public actor RemoteCopyVerifier {
  /// Returns the media key the account holds for a SHA-1, or nil when it holds none.
  public typealias Lookup = @Sendable (_ sha1: Data, _ asLivePhotoMotion: Bool) async throws -> String?

  private let lookup: Lookup
  private let auth: GoogleAuthService?
  private let maxConcurrent: Int
  private let confirmationLifetime: TimeInterval
  /// When each "account|sha1|motion" was last found, so a plan followed by a removal
  /// doesn't ask twice.
  private var confirmedAt: [Confirmation: Date] = [:]
  var cachedConfirmationCount: Int { confirmedAt.count }

  init(
    maxConcurrent: Int = 4, confirmationLifetime: TimeInterval = 10 * 60,
    auth: GoogleAuthService? = nil, lookup: @escaping Lookup
  ) {
    self.auth = auth
    self.lookup = lookup
    self.maxConcurrent = max(1, maxConcurrent)
    self.confirmationLifetime = confirmationLifetime
  }

  public init(client: GooglePhotosMobileClient) {
    self.init(auth: client.authService) { sha1, motion in try await client.findExisting(sha1: sha1, asLivePhotoMotion: motion) }
  }

  /// The records whose every uploaded part is still in `accountEmail`, in their order.
  public func confirmed(_ records: [TransferRecord], accountEmail: String, now: Date = Date()) async -> [TransferRecord] {
    guard !records.isEmpty, !Task.isCancelled else { return [] }
    let credential = await auth?.installedCredential
    guard auth == nil || credential?.email == accountEmail else { return [] }
    let generation = credential?.generation
    var queries: [Query] = []
    var queriesByRecord: [String: [Query]] = [:]
    for record in records {
      guard let parts = Self.queries(for: record, accountEmail: accountEmail) else { continue }
      queriesByRecord[record.id] = parts
      queries.append(contentsOf: parts)
    }
    // Expired confirmations are never used again.
    confirmedAt = confirmedAt.filter { now.timeIntervalSince($0.value) < confirmationLifetime }
    let pending = Array(Set(queries.filter { !isFresh($0, generation: generation, now: now) }))
    let found = await run(pending)
    guard await auth?.installedCredential == credential, !Task.isCancelled else { return [] }
    for query in found {
      confirmedAt[Confirmation(query: query, generation: generation)] = now
    }
    return records.filter { record in
      guard let parts = queriesByRecord[record.id] else { return false }
      return parts.allSatisfy { isFresh($0, generation: generation, now: now) }
    }
  }

  struct Query: Hashable, Sendable {
    let accountEmail: String
    let sha1: Data
    let asLivePhotoMotion: Bool

  }

  private struct Confirmation: Hashable {
    let query: Query
    let generation: Int?
  }

  /// A Live Photo's motion is attached to its still, so it is looked up the way the
  /// upload found it. Nil when the record carries no usable hash.
  static func queries(for record: TransferRecord, accountEmail: String) -> [Query]? {
    guard let encoded = record.sha1, let sha1 = Data(base64Encoded: encoded), sha1.count == 20 else { return nil }
    var parts = [Query(accountEmail: accountEmail, sha1: sha1, asLivePhotoMotion: false)]
    if record.pairedSourcePath != nil || record.pairedSourceSHA1 != nil {
      guard let pairedEncoded = record.pairedSourceSHA1, let paired = Data(base64Encoded: pairedEncoded), paired.count == 20
      else { return nil }
      parts.append(Query(accountEmail: accountEmail, sha1: paired, asLivePhotoMotion: true))
    }
    return parts
  }

  private func isFresh(_ query: Query, generation: Int?, now: Date) -> Bool {
    guard let date = confirmedAt[Confirmation(query: query, generation: generation)] else { return false }
    return now.timeIntervalSince(date) < confirmationLifetime
  }

  private func run(_ queries: [Query]) async -> [Query] {
    guard !queries.isEmpty else { return [] }
    let lookup = self.lookup
    return await withTaskGroup(of: Query?.self) { group in
      var found: [Query] = []
      var iterator = queries.makeIterator()
      func addNext() -> Bool {
        guard !Task.isCancelled, let query = iterator.next() else { return false }
        group.addTask {
          guard !Task.isCancelled else { return nil }
          let key = try? await lookup(query.sha1, query.asLivePhotoMotion)
          return (key?.isEmpty == false) ? query : nil
        }
        return true
      }
      for _ in 0..<maxConcurrent where addNext() {}
      while let result = await group.next() {
        if let result { found.append(result) }
        _ = addNext()
      }
      return found
    }
  }
}
