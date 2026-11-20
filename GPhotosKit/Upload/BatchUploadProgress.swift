import Foundation

/// Byte-weighted batch work. A completed dedup counts as backed up, but never as network traffic.
/// Sent bytes are URLSession's transport estimate, not proof of delivery or a committed item.
public struct BatchUploadProgress: Sendable {
  private struct Item: Sendable {
    var size: Int64
    var sent: Int64 = 0
    var completed = false
  }
  private var items: [String: Item] = [:]
  private var samples: [(time: TimeInterval, bytes: Int64)] = []
  private var traffic: Int64 = 0
  private var hasStarted = false
  private var lastMovement: TimeInterval?
  // Kept as running totals: these are read on every progress tick of batches up to 100,000 items.
  public private(set) var totalBytes: Int64 = 0
  public private(set) var backedUpBytes: Int64 = 0
  public private(set) var transferredBytes: Int64 = 0
  private var completedCount = 0

  public init() {}

  public mutating func include(id: String, size: Int64) {
    guard items[id] == nil else { return }
    let size = max(0, size)
    items[id] = Item(size: size)
    totalBytes += size
  }

  public mutating func resize(id: String, size: Int64) {
    guard var item = items[id], !item.completed else { return }
    let size = max(0, size)
    totalBytes += size - item.size
    item.size = size
    moveSent(of: &item, to: min(item.sent, size))
    items[id] = item
  }

  public mutating func sent(id: String, bytes: Int64, at time: TimeInterval) {
    guard var item = items[id], !item.completed else { return }
    let next = min(item.size, max(item.sent, bytes))
    let delta = next - item.sent
    if delta > 0 {
      traffic += delta
      lastMovement = time
    }
    moveSent(of: &item, to: next)
    items[id] = item
    hasStarted = true
    sample(at: time)
  }

  /// A component already in Google contributes to the batch without contributing to the rate.
  public mutating func creditExisting(id: String, bytes: Int64) {
    guard var item = items[id], !item.completed else { return }
    moveSent(of: &item, to: min(item.size, max(item.sent, bytes)))
    items[id] = item
  }

  public mutating func complete(id: String) {
    guard var item = items[id], !item.completed else { return }
    moveSent(of: &item, to: item.size)
    item.completed = true
    items[id] = item
    backedUpBytes += item.size
    completedCount += 1
  }

  private mutating func moveSent(of item: inout Item, to sent: Int64) {
    transferredBytes += sent - item.sent
    item.sent = sent
  }

  public var fraction: Double {
    guard !items.isEmpty else { return 0 }
    if completedCount == items.count { return 1 }
    guard totalBytes > 0 else { return 0 }
    // The transport can buffer the last bytes before Google accepts and commits the item.
    return min(0.99, Double(transferredBytes) / Double(totalBytes))
  }

  public mutating func sample(at time: TimeInterval) {
    guard hasStarted else { return }
    if let last = samples.last, time - last.time < 0.25 { return }
    samples.append((time, traffic))
    while samples.count > 2 && samples[1].time <= time - 5 { samples.removeFirst() }
  }

  public func speed(at time: TimeInterval) -> Double? {
    guard let lastMovement, time - lastMovement < 3,
      let first = samples.first, let last = samples.last,
      last.time - first.time >= 1, last.bytes > first.bytes
    else { return nil }
    return Double(last.bytes - first.bytes) / (last.time - first.time)
  }
}
