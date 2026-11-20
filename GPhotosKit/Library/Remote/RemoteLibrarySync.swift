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
  }

  private let store: RemoteLibraryStore
  private let fetcher: any RemoteLibraryFetching
  private var running: Task<Progress, Error>?
  static let maxCycles = 10

  public init(store: RemoteLibraryStore, fetcher: any RemoteLibraryFetching) {
    self.store = store
    self.fetcher = fetcher
  }

  /// Runs a sync, or joins the one already running. `onPage` is called after each page is
  /// committed.
  public func sync(onPage: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Progress {
    if let running { return try await running.value }
    let task = Task { try await self.run(onPage: onPage) }
    running = task
    defer { running = nil }
    return try await task.value
  }

  private func run(onPage: @escaping @Sendable (Progress) -> Void) async throws -> Progress {
    var progress = Progress()
    func record(_ update: RemoteLibraryUpdate) {
      progress.pages += 1
      progress.updated += update.items.count
      progress.deleted += update.deletedMediaKeys.count
      onPage(progress)
    }

    if !(try await store.syncState().initialSyncDone) {
      let state = try await store.syncState()
      if !state.resumeToken.isEmpty {
        try await initialPages(from: state.resumeToken, record: record)
      }
      let first = try await fetcher.libraryState(syncToken: state.syncToken)
      try await store.apply(first, syncToken: first.syncToken)
      record(first)
      if !first.resumeToken.isEmpty {
        try await initialPages(from: first.resumeToken, record: record)
      }
      try await store.markInitialSyncDone()
    }

    var previousToken: String?
    for _ in 0..<Self.maxCycles {
      try Task.checkCancellation()
      let token = try await store.syncState().syncToken
      if let previousToken, previousToken == token { throw RemoteLibrarySyncError.cycleWithoutProgress }
      let update = try await fetcher.libraryState(syncToken: token)
      try await store.apply(update, syncToken: update.syncToken)
      record(update)
      var resume = update.resumeToken
      while !resume.isEmpty {
        try Task.checkCancellation()
        let page = try await fetcher.libraryDeltaPage(resumeToken: resume, syncToken: token)
        try await store.apply(page, syncToken: nil)
        record(page)
        resume = page.resumeToken
      }
      guard update.triggersNextSync else { break }
      previousToken = token
    }
    return progress
  }

  private func initialPages(from resumeToken: String, record: (RemoteLibraryUpdate) -> Void) async throws {
    var resume = resumeToken
    while !resume.isEmpty {
      try Task.checkCancellation()
      let page = try await fetcher.libraryInitialPage(resumeToken: resume)
      try await store.apply(page, syncToken: nil)
      record(page)
      resume = page.resumeToken
    }
  }
}
