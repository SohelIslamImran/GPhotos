import Foundation
import os

/// What a cleanup pass was planned under, readable from the manifest actor: changing any of
/// it, or stopping the pass, stops a removal under way.
public final class CleanupPolicy: Sendable {
  private let generation = OSAllocatedUnfairLock(initialState: 0)

  public init() {}

  public func invalidate() { generation.withLock { $0 &+= 1 } }

  /// To tell a removal called off by a change from one that failed.
  public var current: Int { generation.withLock { $0 } }

  /// For `deleteSourceFiles`: the policy still stands, and neither the files nor their
  /// backed-up folder is shared in iCloud now (removing them would remove everyone's copy).
  public func check(root: URL?) -> @Sendable ([URL]) -> Bool {
    let planned = generation.withLock { $0 }
    let generation = generation
    return { files in
      let stands = { !Task.isCancelled && generation.withLock { $0 } == planned }
      guard stands() else { return false }
      if let root, FolderMediaScanner.isSharedCloudItem(root) { return false }
      guard !files.contains(where: FolderMediaScanner.isSharedCloudItem) else { return false }
      // Those reads can take a while.
      return stands()
    }
  }
}
