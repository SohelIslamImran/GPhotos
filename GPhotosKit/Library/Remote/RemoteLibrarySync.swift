import Foundation

/// The library calls a sync needs; the mobile client in the app, a fake in tests.
public protocol RemoteLibraryFetching: Sendable {
  func libraryState(syncToken: String) async throws -> RemoteLibraryUpdate
  func libraryInitialPage(resumeToken: String) async throws -> RemoteLibraryUpdate
  func libraryDeltaPage(resumeToken: String, syncToken: String) async throws -> RemoteLibraryUpdate
}

extension GooglePhotosMobileClient: RemoteLibraryFetching {}

public enum RemoteLibrarySyncError: Error, Equatable {
  /// The server asked for another cycle without moving the sync token.
  case cycleWithoutProgress
}

/// Mirrors the Google Photos library into a `RemoteLibraryStore`. The first sync pages
/// by resume token. Later cycles use the sync token and stop after ten cycles or when the
/// token stops moving. Each page and its tokens are saved before the next request.
public actor RemoteLibrarySync {
  public struct Progress: Sendable, Equatable {
    public var pages = 0
    public var updated = 0
    public var deleted = 0
    /// What the committed pages actually changed in the mirror.
    public var changes = RemoteLibraryStore.Changes()
  }

  private let store: RemoteLibraryStore
  private let fetcher: any RemoteLibraryFetching
  /// Told which items a page moves to the Locked Folder just before it's committed.
  private let willLock: @Sendable (Set<String>) -> Void
  /// Told which items a committed page lists as not locked, or deletes.
  private let didRelease: @Sendable (Set<String>) -> Void
  private var running: Task<Progress, Error>?
  /// The last sync's progress so far, final once it ends, also when it failed part way.
  public private(set) var progress = Progress()
  static let maxCycles = 10

  public init(
    store: RemoteLibraryStore, fetcher: any RemoteLibraryFetching,
    willLock: @escaping @Sendable (Set<String>) -> Void = { _ in },
    didRelease: @escaping @Sendable (Set<String>) -> Void = { _ in }
  ) {
    self.store = store
    self.fetcher = fetcher
    self.willLock = willLock
    self.didRelease = didRelease
  }

  /// Runs a sync, or joins the one already running. `onPage` is called after each page is
  /// committed. Cancelling the caller stops the sync: only one library object joins it.
  public func sync(onPage: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Progress {
    let task: Task<Progress, Error>
    if let running {
      task = running
    } else {
      task = Task { try await self.run(onPage: onPage) }
      running = task
    }
    defer { if running == task { running = nil } }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func run(onPage: @escaping @Sendable (Progress) -> Void) async throws -> Progress {
    progress = Progress()
    // A response that arrives after a cancel (an account switch, a removal) is never written.
    func commit(_ update: RemoteLibraryUpdate, syncToken: String?, deltaToken: String? = nil) async throws {
      try Task.checkCancellation()
      let changes = try await store.apply(update, syncToken: syncToken, deltaToken: deltaToken, willLock: willLock)
      var seen = Set(update.deletedMediaKeys)
      var released = seen
      for item in update.items.reversed() where seen.insert(item.mediaKey).inserted && !item.isLocked {
        released.insert(item.mediaKey)
      }
      didRelease(released)
      progress.pages += 1
      progress.updated += update.items.count
      progress.deleted += update.deletedMediaKeys.count
      progress.changes = progress.changes + changes
      onPage(progress)
    }

    func commitPage(_ update: RemoteLibraryUpdate) async throws {
      try await commit(update, syncToken: nil)
    }

    let initial = try await store.syncState()
    if !initial.initialSyncDone {
      if !initial.resumeToken.isEmpty {
        try await pages(from: initial.resumeToken, commit: commitPage) { [fetcher] in
          try await fetcher.libraryInitialPage(resumeToken: $0)
        }
      }
      try Task.checkCancellation()
      let first = try await fetcher.libraryState(syncToken: initial.syncToken)
      try await commit(first, syncToken: first.syncToken)
      if !first.resumeToken.isEmpty {
        try await pages(from: first.resumeToken, commit: commitPage) { [fetcher] in
          try await fetcher.libraryInitialPage(resumeToken: $0)
        }
      }
      try Task.checkCancellation()
      try await store.markInitialSyncDone()
    }

    let state = try await store.syncState()
    var previousToken: String?
    if let deltaToken = state.deltaToken {
      // The stored sync token opens the next cycle. Pending pages still belong to the old one.
      do {
        try await pages(from: state.resumeToken, commit: commitPage) { [fetcher] in
          try await fetcher.libraryDeltaPage(resumeToken: $0, syncToken: deltaToken)
        }
        if state.deltaTriggersNextSync { previousToken = deltaToken }
      } catch GPhotosError.httpError(let status, _) where [400, 404, 410, 422].contains(status) {
        // Replay the original delta once. Advancing to the next token would skip changes.
        try Task.checkCancellation()
        try await store.restartDelta(from: deltaToken)
      }
    }
    for _ in (previousToken == nil ? 0 : 1)..<Self.maxCycles {
      try Task.checkCancellation()
      let token = try await store.syncState().syncToken
      if let previousToken, previousToken == token { throw RemoteLibrarySyncError.cycleWithoutProgress }
      let update = try await fetcher.libraryState(syncToken: token)
      try await commit(update, syncToken: update.syncToken, deltaToken: token)
      if !update.resumeToken.isEmpty {
        try await pages(from: update.resumeToken, commit: commitPage) { [fetcher] in
          try await fetcher.libraryDeltaPage(resumeToken: $0, syncToken: token)
        }
      }
      guard update.triggersNextSync else { break }
      previousToken = token
    }
    return progress
  }

  /// Follows resume tokens to the last page. The next page is requested while this one is
  /// written, so a first sync of hundreds of pages doesn't wait on each transaction;
  /// requests still go one at a time, in order. If a write fails, the page fetched ahead
  /// is dropped, never committed, and the stored token resumes from the failed page. It
  /// has ended by the time this returns, so a sync that stopped has no request left out.
  private func pages(
    from resumeToken: String, commit: (RemoteLibraryUpdate) async throws -> Void,
    fetch: @escaping @Sendable (String) async throws -> RemoteLibraryUpdate
  ) async throws {
    var ahead: Task<RemoteLibraryUpdate, Error>?
    do {
      var resume = resumeToken
      while !resume.isEmpty {
        try Task.checkCancellation()
        let page: RemoteLibraryUpdate
        if let next = ahead {
          page = try await withTaskCancellationHandler {
            try await next.value
          } onCancel: {
            next.cancel()
          }
          ahead = nil
        } else {
          page = try await fetch(resume)
        }
        try Task.checkCancellation()
        if !page.resumeToken.isEmpty {
          let token = page.resumeToken
          ahead = Task { try await fetch(token) }
        }
        try await commit(page)
        resume = page.resumeToken
      }
    } catch {
      ahead?.cancel()
      _ = await ahead?.result
      throw error
    }
  }
}
