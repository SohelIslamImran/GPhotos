import Foundation

/// A display snapshot of one account's upload history.
public struct AccountTransferBuckets: Sendable {
  public private(set) var accountEmail: String?
  private var records: [TransferRecord] = []
  /// Nil when the selected account can reuse the entire manifest snapshot.
  private var positions: [Int]?
  private var positionsByID: [String: Int] = [:]
  public private(set) var queued: [TransferRecord] = []
  public private(set) var uploadingCount = 0
  public private(set) var sentCount = 0
  public private(set) var failedCount = 0
  public private(set) var completedBytes: Int64 = 0
  public private(set) var lastBackup: Date?

  private var count: Int { positions?.count ?? records.count }
  public var all: [TransferRecord] { positions?.map { records[$0] } ?? records }

  public var activityCounts: [ActivityFilter: Int] {
    [.all: count, .pending: queued.count + uploadingCount, .uploaded: sentCount, .failed: failedCount]
  }

  public init() {}

  public init(records: [TransferRecord], accountEmail: String?) {
    guard let accountEmail else { return }
    self.accountEmail = accountEmail
    self.records = records
    let prefix = "\(accountEmail)|"
    for index in records.indices {
      let record = records[index]
      guard record.id.hasPrefix(prefix), !record.isSkipped else {
        if positions == nil { positions = Array(0..<index) }
        continue
      }
      positions?.append(index)
      positionsByID[record.id] = index
      if let sentAt = record.sentAt, lastBackup.map({ $0 < sentAt }) ?? true { lastBackup = sentAt }
      switch record.status {
      case .sending:
        uploadingCount += 1
      case .pending:
        queued.append(record)
      case .sent, .deleted:
        sentCount += 1
        completedBytes += record.byteCount ?? 0
      case .failed:
        failedCount += 1
      }
    }
  }

  public func activityRows(filter: ActivityFilter, query: String) -> AccountActivityRows {
    AccountActivityRows(accountEmail: accountEmail, records: filter.apply(to: all, query: query))
  }

  public func record(id: String) -> TransferRecord? {
    positionsByID[id].map { records[$0] }
  }

  public func hasSameRecords(as other: Self) -> Bool {
    guard accountEmail == other.accountEmail, count == other.count, uploadingCount == other.uploadingCount, sentCount == other.sentCount,
      queued.count == other.queued.count, failedCount == other.failedCount, completedBytes == other.completedBytes
    else { return false }
    if positions == nil, other.positions == nil { return records == other.records }
    return (0..<count).allSatisfy { index in
      records[positions?[index] ?? index] == other.records[other.positions?[index] ?? index]
    }
  }
}

/// Filtered off the main actor. A completed search from a departed account is never presented.
public struct AccountActivityRows: Sendable {
  private let accountEmail: String?
  private let records: [TransferRecord]

  fileprivate init(accountEmail: String?, records: [TransferRecord]) {
    self.accountEmail = accountEmail
    self.records = records
  }

  public func records(for email: String?) -> [TransferRecord] {
    guard let email, email == accountEmail else { return [] }
    return records
  }
}
