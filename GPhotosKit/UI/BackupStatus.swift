import SwiftUI

/// The single answer to "what is the backup doing right now?", shared by the iPhone
/// dashboard, the Mac window, and the menu bar so they can never disagree.
public enum BackupStatus: Equatable, Sendable {
  public enum Source: Equatable, Sendable {
    case photoLibrary
    case folders
  }

  public enum SourceIssue: Equatable, Sendable {
    /// Photos access has not been granted. `canPrompt` is true while iOS can still ask.
    case photosAccessNeeded(canPrompt: Bool)
    case limitedPhotosAccess
    case noFolders
    case foldersBlocked(count: Int)
  }

  case credentialsUnavailable(String)
  case signedOut
  case importFailed(String)
  case stopping
  case paused
  /// Uploads are held until Wi‑Fi because metered networks are turned off.
  case waitingForNetwork
  case offline
  /// Google asked for fewer requests; uploads pick up again on their own.
  case rateLimited
  case syncing(itemCount: Int)
  case scanning(Source)
  case needsSource(SourceIssue)
  case failed(count: Int)
  case waiting(count: Int)
  case waitingForBackgroundBackup
  case albumsNeedAttention(String)
  case autoSyncOff
  case stopped
  case cleanedUp(String)
  case upToDate

  public struct Inputs: Sendable {
    public var credentialError: String?
    /// Set until the first launch pass has loaded the account and looked for new items.
    public var isStarting = false
    public var isSignedIn = false
    public var importError: String?
    public var isRunning = false
    public var isStopping = false
    public var isPaused = false
    public var isWaitingForNetwork = false
    public var isOffline = false
    public var isRateLimited = false
    public var isScanning = false
    public var source: Source = .photoLibrary
    public var sourceIssue: SourceIssue?
    public var uploadingCount = 0
    public var queuedCount = 0
    public var failedCount = 0
    public var isWaitingForBackgroundBackup = false
    public var albumWarning: String?
    public var autoSyncEnabled = true
    public var isStoppedForSession = false
    public var cleanupMessage: String?

    public init() {}
  }

  /// Order matters: a state that blocks backup outranks one that merely describes it,
  /// and an active transfer outranks a configuration problem it is already past.
  public init(_ inputs: Inputs) {
    if let error = inputs.credentialError {
      // An unreadable keychain otherwise looks like "signed out", and signing in again
      // would fail for the same reason.
      self = .credentialsUnavailable(error)
    } else if let error = inputs.importError {
      self = .importFailed(error)
    } else if inputs.isStarting && !inputs.isRunning {
      // Reads as one "looking" step at launch, rather than flashing "signed out" before the
      // account loads and then "looking" again.
      self = .scanning(inputs.source)
    } else if !inputs.isSignedIn {
      self = .signedOut
    } else if inputs.isRunning {
      if inputs.isStopping {
        self = .stopping
      } else if inputs.isPaused {
        self = .paused
      } else if inputs.isOffline {
        self = .offline
      } else if inputs.isWaitingForNetwork {
        self = .waitingForNetwork
      } else if inputs.isRateLimited {
        self = .rateLimited
      } else {
        self = .syncing(itemCount: inputs.uploadingCount + inputs.queuedCount)
      }
    } else if inputs.isScanning {
      self = .scanning(inputs.source)
    } else if let issue = inputs.sourceIssue, issue != .limitedPhotosAccess {
      self = .needsSource(issue)
    } else if inputs.failedCount > 0 {
      self = .failed(count: inputs.failedCount)
    } else if inputs.isStoppedForSession && inputs.autoSyncEnabled {
      self = .stopped
    } else if inputs.queuedCount > 0 && inputs.isOffline {
      self = .offline
    } else if inputs.queuedCount > 0 && inputs.isWaitingForNetwork {
      self = .waitingForNetwork
    } else if inputs.isWaitingForBackgroundBackup {
      self = .waitingForBackgroundBackup
    } else if inputs.queuedCount > 0 {
      self = .waiting(count: inputs.queuedCount)
    } else if let warning = inputs.albumWarning {
      self = .albumsNeedAttention(warning)
    } else if !inputs.autoSyncEnabled {
      self = .autoSyncOff
    } else if inputs.isStoppedForSession {
      self = .stopped
    } else if inputs.sourceIssue == .limitedPhotosAccess {
      self = .needsSource(.limitedPhotosAccess)
    } else if let message = inputs.cleanupMessage {
      self = .cleanedUp(message)
    } else {
      self = .upToDate
    }
  }

  public var title: String {
    switch self {
    case .credentialsUnavailable: String(localized: "Can’t Read Your Account")
    case .signedOut: String(localized: "Back Up to Google Photos")
    case .importFailed: String(localized: "Import Needs Attention")
    case .stopping: String(localized: "Stopping…")
    case .paused: String(localized: "Backup Paused")
    case .waitingForNetwork: String(localized: "Waiting for Wi‑Fi")
    case .offline: String(localized: "Waiting for a Connection")
    case .rateLimited: String(localized: "Waiting on Google Photos")
    case .syncing(let count):
      count > 1 ? String(localized: "Backing Up \(count) Items") : String(localized: "Backing Up")
    case .scanning: String(localized: "Looking for New Items")
    case .needsSource(.photosAccessNeeded): String(localized: "Allow Photos Access")
    case .needsSource(.limitedPhotosAccess): String(localized: "Up to Date")
    case .needsSource(.noFolders): String(localized: "Choose a Folder")
    case .needsSource(.foldersBlocked): String(localized: "Folder Access Needed")
    case .failed(let count):
      count == 1 ? String(localized: "1 Upload Failed") : String(localized: "\(count) Uploads Failed")
    case .waiting(let count):
      count == 1 ? String(localized: "1 Item Waiting") : String(localized: "\(count) Items Waiting")
    case .waitingForBackgroundBackup: String(localized: "Waiting for Background Backup")
    case .albumsNeedAttention: String(localized: "Albums Need Attention")
    case .autoSyncOff: String(localized: "Auto-Sync Off")
    case .stopped: String(localized: "Backup Stopped")
    case .cleanedUp: String(localized: "Cleaned Up")
    case .upToDate: String(localized: "Up to Date")
    }
  }

  /// The case without its payload, so a view keyed on it keeps its identity while counts and
  /// messages change.
  public var kind: String {
    switch self {
    case .credentialsUnavailable: "credentialsUnavailable"
    case .signedOut: "signedOut"
    case .importFailed: "importFailed"
    case .stopping: "stopping"
    case .paused: "paused"
    case .waitingForNetwork: "waitingForNetwork"
    case .offline: "offline"
    case .rateLimited: "rateLimited"
    case .syncing: "syncing"
    case .scanning(.photoLibrary): "scanning.photoLibrary"
    case .scanning(.folders): "scanning.folders"
    case .needsSource(.photosAccessNeeded): "needsSource.photosAccessNeeded"
    case .needsSource(.limitedPhotosAccess): "needsSource.limitedPhotosAccess"
    case .needsSource(.noFolders): "needsSource.noFolders"
    case .needsSource(.foldersBlocked): "needsSource.foldersBlocked"
    case .failed: "failed"
    case .waiting: "waiting"
    case .waitingForBackgroundBackup: "waitingForBackgroundBackup"
    case .albumsNeedAttention: "albumsNeedAttention"
    case .autoSyncOff: "autoSyncOff"
    case .stopped: "stopped"
    case .cleanedUp: "cleanedUp"
    case .upToDate: "upToDate"
    }
  }

  public var subtitle: String {
    switch self {
    case .credentialsUnavailable(let message), .importFailed(let message), .albumsNeedAttention(let message),
      .cleanedUp(let message):
      message
    case .signedOut: String(localized: "Sign in with Google to start backing up.")
    case .stopping: String(localized: "Finishing the current transfer.")
    case .paused: Self.pausedSubtitle
    case .waitingForNetwork: Self.waitingForNetworkSubtitle
    case .offline: String(localized: "Backup resumes when you’re back online.")
    case .rateLimited: String(localized: "Google Photos asked for fewer requests. Backup resumes automatically.")
    case .syncing: String(localized: "Original quality")
    case .scanning(.photoLibrary): String(localized: "Checking your photo library.")
    case .scanning(.folders): String(localized: "Checking your watched folders.")
    case .needsSource(.photosAccessNeeded(let canPrompt)):
      canPrompt
        ? String(localized: "Allow access so new photos can be backed up.")
        : String(localized: "Turn on Photos access in Settings to back up your library.")
    case .needsSource(.limitedPhotosAccess): String(localized: "Backing up only the photos you selected.")
    case .needsSource(.noFolders): String(localized: "Add a folder to back up its photos and videos.")
    case .needsSource(.foldersBlocked(let count)):
      count == 1
        ? String(localized: "macOS blocked access to a folder. Choose it again to continue.")
        : String(localized: "macOS blocked access to \(count) folders. Choose them again to continue.")
    case .failed: String(localized: "Retry, or open Activity to see what went wrong.")
    case .waiting: String(localized: "They’ll upload on the next sync.")
    case .waitingForBackgroundBackup: String(localized: "Photos scheduled these items to back up in the background.")
    case .autoSyncOff: Self.autoSyncOffSubtitle
    case .stopped: Self.stoppedSubtitle
    case .upToDate: ProductCopy.originalQuality
    }
  }

  // Clicked on the Mac, tapped on the iPhone.
  #if os(macOS)
    private static var pausedSubtitle: String { String(localized: "Click Resume to continue.") }
    private static var autoSyncOffSubtitle: String { String(localized: "New photos upload only when you click Sync Now.") }
    private static var stoppedSubtitle: String { String(localized: "Click Sync Now to continue backing up.") }
    private static var waitingForNetworkSubtitle: String {
      String(localized: "Backup continues on Wi‑Fi or Ethernet, or turn on Use Personal Hotspot.")
    }
  #else
    private static var pausedSubtitle: String { String(localized: "Tap Resume to continue.") }
    private static var autoSyncOffSubtitle: String { String(localized: "New photos upload only when you tap Sync Now.") }
    private static var stoppedSubtitle: String { String(localized: "Tap Sync Now to continue backing up.") }
    private static var waitingForNetworkSubtitle: String {
      String(localized: "Backup continues on Wi‑Fi, or turn on Use Cellular Data.")
    }
  #endif

  public var symbol: String {
    switch self {
    case .credentialsUnavailable: "person.crop.circle.badge.exclamationmark"
    case .signedOut: "icloud.and.arrow.up"
    case .importFailed, .failed, .albumsNeedAttention: "exclamationmark.triangle.fill"
    case .stopping: "hourglass"
    case .paused, .autoSyncOff: "pause.fill"
    case .syncing: "arrow.triangle.2.circlepath"
    case .scanning: "magnifyingglass"
    case .needsSource(.photosAccessNeeded): "photo.badge.exclamationmark"
    case .needsSource(.limitedPhotosAccess): "checkmark"
    case .needsSource(.noFolders): "folder.badge.plus"
    case .needsSource(.foldersBlocked): "lock.fill"
    case .waiting: "clock.fill"
    case .waitingForNetwork, .offline: "wifi.exclamationmark"
    case .waitingForBackgroundBackup: "clock.fill"
    case .rateLimited: "hourglass"
    case .stopped: "stop.fill"
    case .cleanedUp: "sparkles"
    case .upToDate: "checkmark"
    }
  }

  /// The menu bar shows a quieter, outline-weight set so it sits with system icons.
  public var menuBarSymbol: String {
    switch self {
    case .syncing: "arrow.triangle.2.circlepath"
    case .scanning: "magnifyingglass"
    case .paused, .stopping, .autoSyncOff, .stopped: "pause.circle"
    case .waitingForNetwork, .offline: "wifi.exclamationmark"
    case .rateLimited: "hourglass"
    case .credentialsUnavailable, .importFailed, .failed, .albumsNeedAttention, .needsSource(.foldersBlocked):
      "exclamationmark.triangle"
    default: "photo.on.rectangle.angled"
    }
  }

  /// The status colour by name, so the widgets (which read it from a file) match.
  public enum Tone: String, Codable, Sendable {
    case red, orange, blue, accent, gray, green

    public var color: Color {
      switch self {
      case .red: .red
      case .orange: .orange
      case .blue: .blue
      case .accent: .accentColor
      case .gray: .gray
      case .green: .green
      }
    }
  }

  public var tone: Tone {
    switch self {
    case .credentialsUnavailable, .importFailed, .failed: .red
    case .albumsNeedAttention, .needsSource(.photosAccessNeeded), .needsSource(.noFolders),
      .needsSource(.foldersBlocked), .waiting, .waitingForNetwork, .offline, .rateLimited, .waitingForBackgroundBackup:
      .orange
    case .syncing, .scanning: .blue
    case .signedOut: .accent
    case .stopping, .paused, .autoSyncOff, .stopped: .gray
    case .needsSource(.limitedPhotosAccess), .cleanedUp, .upToDate: .green
    }
  }

  public var tint: Color { tone.color }

  /// Only the sync arrows spin; other active states pulse.
  public var rotates: Bool {
    if case .syncing = self { return true }
    return false
  }

  public var isScan: Bool {
    if case .scanning = self { return true }
    return false
  }

  /// Whether work is in flight, which drives the emblem's motion.
  public var isActive: Bool {
    switch self {
    case .syncing, .scanning, .stopping: true
    default: false
    }
  }

  /// Whether the card offers a second action next to the primary one.
  public var hasSecondaryAction: Bool {
    switch self {
    case .failed, .needsSource(.limitedPhotosAccess): true
    default: false
    }
  }
}

/// Shows `status`, except that entering a scan waits a moment. A scan that ends within
/// moments otherwise flashes "Looking for New Items" and swaps the surface's buttons
/// twice. Every other change shows at once. Shared so the iPhone dashboard, the Mac
/// window, the menu bar panel and the menu bar icon settle the same way.
public struct DisplayedBackupStatus<Content: View>: View {
  private let status: BackupStatus
  private let content: (BackupStatus) -> Content
  /// What the surface last settled on.
  @State private var shown: BackupStatus?

  public init(_ status: BackupStatus, @ViewBuilder content: @escaping (BackupStatus) -> Content) {
    self.status = status
    self.content = content
  }

  public var body: some View {
    content(displayed)
      .task(id: status) {
        if status.isScan, let current = shown, !current.isScan {
          do { try await Task.sleep(for: .seconds(0.6)) } catch { return }
        }
        shown = status
      }
  }

  private var displayed: BackupStatus {
    guard status.isScan, let shown, !shown.isScan else { return status }
    return shown
  }
}

extension ProductCopy {
  /// Why Clean Up is unavailable, or what it does, for the settings row and any menu
  /// item that offers it.
  public static func cleanupDetail(isSignedIn: Bool, deleteDelay: AutoDeleteDelay, isBackingUp: Bool) -> LocalizedStringKey {
    if !isSignedIn { return "Sign in to Google Photos to use this." }
    if deleteDelay == .never { return "Choose a Delete After Backup time to use this." }
    if isBackingUp { return "Available when the current backup finishes." }
    #if os(macOS)
      return "Remove backed-up files from this Mac now."
    #else
      return "Remove backed-up items from this iPhone now."
    #endif
  }

  /// A hash match shows the bytes are in the account, not the quality Google kept.
  public static func foundItemsDetail(count: Int, isOn: Bool, deleteDelay: AutoDeleteDelay) -> LocalizedStringKey {
    if deleteDelay == .never { return "Choose a Delete After Backup time to use this." }
    if isOn { return "Also removes items that were already in Google Photos." }
    if count == 0 { return "Items already in Google Photos stay, as they may be a Storage saver copy." }
    return "^[\(count) item](inflect: true) already in Google Photos stay, as they may be a Storage saver copy."
  }
}
