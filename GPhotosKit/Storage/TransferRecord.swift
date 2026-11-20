import Foundation

public enum TransferStatus: String, Codable, Sendable, Equatable {
  case pending
  case sending
  case sent
  case failed
  case deleted

  public var title: String {
    switch self {
    case .pending: "Pending"
    case .sending: "Uploading"
    case .sent: "Uploaded"
    case .failed: "Failed"
    case .deleted: "Deleted"
    }
  }
}

public enum AutoDeleteDelay: String, CaseIterable, Codable, Sendable, Identifiable, Equatable {
  case never
  case immediately
  case oneDay
  case oneWeek
  case fifteenDays
  case thirtyDays

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .never: "Never"
    case .immediately: "Immediately"
    case .oneDay: "24 hours"
    case .oneWeek: "1 week"
    case .fifteenDays: "15 days"
    case .thirtyDays: "30 days"
    }
  }

  public var interval: TimeInterval? {
    switch self {
    case .never: nil
    case .immediately: 0
    case .oneDay: 24 * 60 * 60
    case .oneWeek: 7 * 24 * 60 * 60
    case .fifteenDays: 15 * 24 * 60 * 60
    case .thirtyDays: 30 * 24 * 60 * 60
    }
  }
}

/// Which of a photo-library asset's resources a record uploads. Most assets have one; a
/// RAW+JPEG pair carries its RAW as an `.alternatePhoto` resource, and an edited asset its
/// unedited original as `.uneditedOriginal`, each uploaded as another record of the asset.
public enum AssetResourceRole: String, Codable, Sendable {
  case primary
  case alternatePhoto
  case uneditedOriginal
}

public struct TransferRecord: Identifiable, Codable, Hashable, Sendable {
  struct PreparedAsset: Codable, Hashable, Sendable {
    let modifiedAt: Date?
    var hasAdjustments: Bool? = nil
    var adjustmentTimestamp: Date? = nil
    let sha1: String
    let motionSHA1: String?

    var version: AssetVersion {
      AssetVersion(modifiedAt: modifiedAt, hasAdjustments: hasAdjustments, adjustmentTimestamp: adjustmentTimestamp)
    }
  }

  public struct AssetVersion: Sendable {
    public let modifiedAt: Date?
    public let hasAdjustments: Bool?
    public let adjustmentTimestamp: Date?

    public init(modifiedAt: Date?, hasAdjustments: Bool? = nil, adjustmentTimestamp: Date? = nil) {
      self.modifiedAt = modifiedAt
      self.hasAdjustments = hasAdjustments
      self.adjustmentTimestamp = adjustmentTimestamp
    }

    public func contentChanged(since uploaded: Self) -> Bool {
      if let hasAdjustments, let previous = uploaded.hasAdjustments {
        if hasAdjustments != previous { return true }
        if !hasAdjustments { return false }
      }
      if let adjustmentTimestamp {
        if let previous = uploaded.adjustmentTimestamp { return adjustmentTimestamp != previous }
        // For a receipt without an edit timestamp, an edit after the recorded version is new.
        return TransferRecord.isAssetEdited(adjustmentTimestamp, since: uploaded.modifiedAt)
      }
      return (hasAdjustments == true || uploaded.hasAdjustments == true)
        && TransferRecord.isAssetEdited(modifiedAt, since: uploaded.modifiedAt)
    }
  }

  public let id: String
  public var filename: String
  public var mediaType: String
  public var creationDate: Date?
  public var status: TransferStatus
  public var progress: Double
  public var byteCount: Int64?
  public var transferredByteCount: Int64
  public var attempts: Int
  /// When the last attempt failed, which spaces out automatic retries.
  public var lastFailedAt: Date?
  public var sentAt: Date?
  public var deletedAt: Date?
  public var deleteAfter: Date?
  public var sentAccountEmails: Set<String>
  /// Google Photos media key per account. The only place a media key is stored.
  public var mediaKeysByAccount: [String: String]
  /// Accounts that already held these bytes, so this app never uploaded them there. A
  /// hash match does not show the quality Google keeps: it may be a Storage saver copy.
  public var foundInAccounts: Set<String>
  public var sha1: String?
  public var lastError: String?
  public var sourcePath: String?
  public var pairedSourcePath: String?
  public var assetLocalIdentifier: String?
  public var assetModifiedAt: Date?
  public var assetHadAdjustments: Bool?
  public var assetAdjustmentTimestamp: Date?
  /// An export that was hashed but whose upload hasn't been recorded as successful.
  var preparedAsset: PreparedAsset?
  public var sharedEntryID: UUID?
  public var sourceFileSize: Int64?
  public var sourceModifiedAt: Date?
  public var sourceSHA1: String?
  public var pairedSourceFileSize: Int64?
  public var pairedSourceModifiedAt: Date?
  public var pairedSourceSHA1: String?
  public var resourceRole: AssetResourceRole
  /// Set once the asset's resources have been read from PhotoKit for this record, so a
  /// primary uploaded before RAW support is looked up for a RAW at most once.
  public var isSkipped = false
  public var resourcesChecked: Bool

  public var isTerminalSuccess: Bool {
    status == .sent || status == .deleted
  }

  public var assetVersion: AssetVersion {
    AssetVersion(modifiedAt: assetModifiedAt, hasAdjustments: assetHadAdjustments, adjustmentTimestamp: assetAdjustmentTimestamp)
  }

  public func hasBackedUpAsset(to accountEmail: String, version: AssetVersion) -> Bool {
    isTerminalSuccess && sentAccountEmails.contains(accountEmail)
      && (resourceRole == .uneditedOriginal || !version.contentChanged(since: assetVersion))
  }

  public static func isAssetEdited(_ modifiedAt: Date?, since recorded: Date?) -> Bool {
    guard let modifiedAt else { return false }
    return recorded.map { modifiedAt > $0 } ?? true
  }

  public init(
    id: String,
    filename: String,
    mediaType: String,
    creationDate: Date? = nil,
    status: TransferStatus,
    progress: Double = 0,
    byteCount: Int64? = nil,
    transferredByteCount: Int64 = 0,
    attempts: Int = 0,
    sentAt: Date? = nil,
    deletedAt: Date? = nil,
    deleteAfter: Date? = nil,
    sentAccountEmails: Set<String> = [],
    mediaKeysByAccount: [String: String] = [:],
    foundInAccounts: Set<String> = [],
    sha1: String? = nil,
    lastError: String? = nil,
    sourcePath: String? = nil,
    pairedSourcePath: String? = nil,
    assetLocalIdentifier: String? = nil,
    assetModifiedAt: Date? = nil,
    assetHadAdjustments: Bool? = nil,
    assetAdjustmentTimestamp: Date? = nil,
    sharedEntryID: UUID? = nil,
    sourceFileSize: Int64? = nil,
    sourceModifiedAt: Date? = nil,
    sourceSHA1: String? = nil,
    pairedSourceFileSize: Int64? = nil,
    pairedSourceModifiedAt: Date? = nil,
    pairedSourceSHA1: String? = nil,
    resourceRole: AssetResourceRole = .primary,
    resourcesChecked: Bool = false
  ) {
    self.id = id
    self.filename = filename
    self.mediaType = mediaType
    self.creationDate = creationDate
    self.status = status
    self.progress = progress
    self.byteCount = byteCount
    self.transferredByteCount = transferredByteCount
    self.attempts = attempts
    self.sentAt = sentAt
    self.deletedAt = deletedAt
    self.deleteAfter = deleteAfter
    self.sentAccountEmails = sentAccountEmails
    self.mediaKeysByAccount = mediaKeysByAccount
    self.foundInAccounts = foundInAccounts
    self.sha1 = sha1
    self.lastError = lastError
    self.sourcePath = sourcePath
    self.pairedSourcePath = pairedSourcePath
    self.assetLocalIdentifier = assetLocalIdentifier
    self.assetModifiedAt = assetModifiedAt
    self.assetHadAdjustments = assetHadAdjustments
    self.assetAdjustmentTimestamp = assetAdjustmentTimestamp
    self.sharedEntryID = sharedEntryID
    self.sourceFileSize = sourceFileSize
    self.sourceModifiedAt = sourceModifiedAt
    self.sourceSHA1 = sourceSHA1
    self.pairedSourceFileSize = pairedSourceFileSize
    self.pairedSourceModifiedAt = pairedSourceModifiedAt
    self.pairedSourceSHA1 = pairedSourceSHA1
    self.resourceRole = resourceRole
    self.resourcesChecked = resourcesChecked
  }

  public init(copying record: TransferRecord, id: String) {
    self.id = id
    self.filename = record.filename
    self.mediaType = record.mediaType
    self.creationDate = record.creationDate
    self.status = record.status
    self.progress = record.progress
    self.byteCount = record.byteCount
    self.transferredByteCount = record.transferredByteCount
    self.attempts = record.attempts
    self.lastFailedAt = record.lastFailedAt
    self.sentAt = record.sentAt
    self.deletedAt = record.deletedAt
    self.deleteAfter = record.deleteAfter
    self.sentAccountEmails = record.sentAccountEmails
    self.mediaKeysByAccount = record.mediaKeysByAccount
    self.foundInAccounts = record.foundInAccounts
    self.sha1 = record.sha1
    self.lastError = record.lastError
    self.sourcePath = record.sourcePath
    self.pairedSourcePath = record.pairedSourcePath
    self.assetLocalIdentifier = record.assetLocalIdentifier
    self.assetModifiedAt = record.assetModifiedAt
    self.assetHadAdjustments = record.assetHadAdjustments
    self.assetAdjustmentTimestamp = record.assetAdjustmentTimestamp
    self.preparedAsset = record.preparedAsset
    self.sharedEntryID = record.sharedEntryID
    self.sourceFileSize = record.sourceFileSize
    self.sourceModifiedAt = record.sourceModifiedAt
    self.sourceSHA1 = record.sourceSHA1
    self.pairedSourceFileSize = record.pairedSourceFileSize
    self.pairedSourceModifiedAt = record.pairedSourceModifiedAt
    self.pairedSourceSHA1 = record.pairedSourceSHA1
    self.resourceRole = record.resourceRole
    self.resourcesChecked = record.resourcesChecked
    self.isSkipped = record.isSkipped
  }

  public static func accountScopedID(_ id: String, accountEmail: String) -> String {
    "\(accountEmail)|\(id)"
  }

  public static func accountEmail(fromScopedID id: String) -> String? {
    accountSeparator(in: id).map { String(id[..<$0]) }
  }

  public static func unscopedID(from id: String) -> String {
    accountSeparator(in: id).map { String(id[id.index(after: $0)...]) } ?? id
  }

  /// The `|` after an account prefix, found without splitting: these run once per record
  /// in sweeps over the whole manifest.
  private static func accountSeparator(in id: String) -> String.Index? {
    guard let separator = id.firstIndex(of: "|"), separator != id.startIndex,
      id.index(after: separator) != id.endIndex
    else { return nil }
    let candidate = id[..<separator]
    return candidate.contains("@") && !candidate.contains("/") ? separator : nil
  }

  /// The record of an asset's RAW, beside its primary record `primaryID` (itself
  /// account-scoped), so both carry the same account prefix.
  public static func alternatePhotoID(forPrimaryID primaryID: String) -> String {
    "\(primaryID)#raw"
  }

  /// The record of an edited asset's unedited original, beside its primary record.
  public static func uneditedOriginalID(forPrimaryID primaryID: String) -> String {
    "\(primaryID)#original"
  }
}

extension TransferRecord {
  /// Synthesized decoding except that `resourceRole`, `resourcesChecked` and
  /// `foundInAccounts`, added after records were first written, fall back to `.primary`,
  /// `false` and none.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.filename = try container.decode(String.self, forKey: .filename)
    self.mediaType = try container.decode(String.self, forKey: .mediaType)
    self.creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate)
    self.status = try container.decode(TransferStatus.self, forKey: .status)
    self.progress = try container.decode(Double.self, forKey: .progress)
    self.byteCount = try container.decodeIfPresent(Int64.self, forKey: .byteCount)
    self.transferredByteCount = try container.decode(Int64.self, forKey: .transferredByteCount)
    self.attempts = try container.decode(Int.self, forKey: .attempts)
    self.lastFailedAt = try container.decodeIfPresent(Date.self, forKey: .lastFailedAt)
    self.sentAt = try container.decodeIfPresent(Date.self, forKey: .sentAt)
    self.deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    self.deleteAfter = try container.decodeIfPresent(Date.self, forKey: .deleteAfter)
    self.sentAccountEmails = try container.decode(Set<String>.self, forKey: .sentAccountEmails)
    self.mediaKeysByAccount = try container.decode([String: String].self, forKey: .mediaKeysByAccount)
    self.foundInAccounts = try container.decodeIfPresent(Set<String>.self, forKey: .foundInAccounts) ?? []
    self.sha1 = try container.decodeIfPresent(String.self, forKey: .sha1)
    self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    self.sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
    self.pairedSourcePath = try container.decodeIfPresent(String.self, forKey: .pairedSourcePath)
    self.assetLocalIdentifier = try container.decodeIfPresent(String.self, forKey: .assetLocalIdentifier)
    self.assetModifiedAt = try container.decodeIfPresent(Date.self, forKey: .assetModifiedAt)
    self.assetHadAdjustments = try container.decodeIfPresent(Bool.self, forKey: .assetHadAdjustments)
    self.assetAdjustmentTimestamp = try container.decodeIfPresent(Date.self, forKey: .assetAdjustmentTimestamp)
    self.preparedAsset = try container.decodeIfPresent(PreparedAsset.self, forKey: .preparedAsset)
    self.sharedEntryID = try container.decodeIfPresent(UUID.self, forKey: .sharedEntryID)
    self.sourceFileSize = try container.decodeIfPresent(Int64.self, forKey: .sourceFileSize)
    self.sourceModifiedAt = try container.decodeIfPresent(Date.self, forKey: .sourceModifiedAt)
    self.sourceSHA1 = try container.decodeIfPresent(String.self, forKey: .sourceSHA1)
    self.pairedSourceFileSize = try container.decodeIfPresent(Int64.self, forKey: .pairedSourceFileSize)
    self.pairedSourceModifiedAt = try container.decodeIfPresent(Date.self, forKey: .pairedSourceModifiedAt)
    self.pairedSourceSHA1 = try container.decodeIfPresent(String.self, forKey: .pairedSourceSHA1)
    self.resourceRole = try container.decodeIfPresent(AssetResourceRole.self, forKey: .resourceRole) ?? .primary
    self.isSkipped = try container.decodeIfPresent(Bool.self, forKey: .isSkipped) ?? false
    self.resourcesChecked = try container.decodeIfPresent(Bool.self, forKey: .resourcesChecked) ?? false
  }
}

public struct IgnoredFolderLocation: Identifiable, Codable, Hashable, Sendable {
  public let id: String
  public var title: String
  public let path: String
  public var bookmarkData: Data?

  public init(url: URL, displayName: String? = nil, bookmarkData: Data? = nil) {
    let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.id = url.standardizedFileURL.path
    self.title = trimmed.isEmpty ? (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent) : trimmed
    self.path = url.standardizedFileURL.path
    self.bookmarkData = bookmarkData
  }

  /// Where the bookmark resolves now; nil without a bookmark or once it no longer
  /// resolves.
  public var bookmarkResolvedURL: URL? {
    guard let bookmarkData else { return nil }
    var isStale = false
    #if os(macOS)
      let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    #else
      let options: URL.BookmarkResolutionOptions = []
    #endif
    return try? URL(resolvingBookmarkData: bookmarkData, options: options, relativeTo: nil, bookmarkDataIsStale: &isStale)
  }

  /// Whether the folder can be found through its bookmark or at its recorded path. A
  /// folder that can't makes cleanup remove nothing. Touches the file system.
  public var canBeFound: Bool {
    bookmarkResolvedURL != nil || FileManager.default.fileExists(atPath: path)
  }

  /// Every path the protected `folders` may be known by: as recorded, wherever each
  /// bookmark now resolves, and both with symbolic links resolved. Checking all of them
  /// errs towards keeping a file. Nil when a folder can be found neither through its
  /// bookmark nor at its recorded path: cleanup then removes no folder file at all
  /// rather than risk one inside it. Touches the file system, so callers run it off the
  /// main actor, once per pass.
  public static func protectedPaths(_ folders: [IgnoredFolderLocation]) -> [String]? {
    var paths: [String] = []
    for folder in folders {
      let recorded = URL(fileURLWithPath: folder.path, isDirectory: true)
      let resolved = folder.bookmarkResolvedURL
      // `canBeFound`, without resolving the bookmark twice.
      guard resolved != nil || FileManager.default.fileExists(atPath: recorded.path) else { return nil }
      for url in [recorded, resolved].compactMap({ $0 }) {
        for path in [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path].map(WatchedFolderPaths.privatePrefixed)
        where !paths.contains(path) {
          paths.append(path)
        }
      }
    }
    return paths
  }

  /// Whether `fileURL`, as given, standardized or with symbolic links resolved, lies in
  /// one of `protectedPaths`.
  public static func isProtected(_ fileURL: URL, protectedPaths: [String]) -> Bool {
    guard !protectedPaths.isEmpty else { return false }
    var candidates: [String] = []
    for path in [fileURL.path, fileURL.standardizedFileURL.path, fileURL.resolvingSymlinksInPath().path].map(
      WatchedFolderPaths.privatePrefixed)
    where !candidates.contains(path) {
      candidates.append(path)
    }
    return protectedPaths.contains { protected in
      candidates.contains { FolderMediaScanner.isInsideProtectedFolder(URL(fileURLWithPath: $0), ignored: protected) }
    }
  }
}

extension TransferRecord {
  /// Automatic retries of an item that keeps failing, doubling up to once a day, so one that
  /// can't go up (too big for the free space, say) isn't exported and hashed on every scan.
  static let firstRetryDelay: TimeInterval = 5 * 60
  static let longestRetryDelay: TimeInterval = 24 * 60 * 60

  /// Whether a scan may try this failed item again by itself.
  public func isDueForAutomaticRetry(at now: Date = Date()) -> Bool {
    guard !isSkipped else { return false }
    guard status == .failed, attempts > 0, let lastFailedAt else { return true }
    let delay = min(Self.longestRetryDelay, Self.firstRetryDelay * pow(2, Double(min(attempts - 1, 16))))
    return now.timeIntervalSince(lastFailedAt) >= delay
  }
}
