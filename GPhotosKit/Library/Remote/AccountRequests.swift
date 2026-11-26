import os

/// The requests a library has out on the client its account shares with others. A request
/// picks up the client's credential only as it's sent, so before that changes to another
/// account, `close` refuses new ones and cancels the rest, and `drain` waits for them to end.
final class AccountRequests: Sendable {
  private struct Running: Sendable {
    let cancel: @Sendable () -> Void
    let finish: @Sendable () async -> Void
  }

  private struct State {
    var isClosed = false
    var nextID: UInt64 = 0
    var running: [UInt64: Running] = [:]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  var isClosed: Bool { state.withLock { $0.isClosed } }

  /// Runs a request, or throws `CancellationError` without starting it once closed.
  func run<T: Sendable>(_ request: @escaping @Sendable () async throws -> T) async throws -> T {
    try Task.checkCancellation()
    let started: (id: UInt64, task: Task<T, Error>)? = state.withLock { state in
      guard !state.isClosed else { return nil }
      let task = Task { try await request() }
      state.nextID &+= 1
      state.running[state.nextID] = Running(cancel: { task.cancel() }, finish: { _ = await task.result })
      return (state.nextID, task)
    }
    guard let started else { throw CancellationError() }
    defer { state.withLock { $0.running[started.id] = nil } }
    return try await withTaskCancellationHandler {
      try await started.task.value
    } onCancel: {
      started.task.cancel()
    }
  }

  func close() {
    let running = state.withLock { state in
      state.isClosed = true
      return Array(state.running.values)
    }
    for request in running { request.cancel() }
  }

  /// Returns once every request has ended. Close first.
  func drain() async {
    for request in state.withLock({ Array($0.running.values) }) { await request.finish() }
  }
}
