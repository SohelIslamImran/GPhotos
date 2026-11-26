import Foundation
import os

/// How long photos opened in the viewer stay on the device during automatic cleanup.
public enum RecentlyViewedRetention: String, Codable, CaseIterable, Sendable {
  case off
  case week
  case month

  public var interval: TimeInterval? {
    switch self {
    case .off: nil
    case .week: 7 * 24 * 60 * 60
    case .month: 30 * 24 * 60 * 60
    }
  }

  public var title: String {
    switch self {
    case .off: String(localized: "Off")
    case .week: String(localized: "1 Week")
    case .month: String(localized: "1 Month")
    }
  }
}

public struct AppSettings: Codable, Sendable, Equatable {
  public var autoDeleteDelay: AutoDeleteDelay
  public var smartDeleteEnabled: Bool
  /// Also lets cleanup remove items whose bytes were already in Google Photos before this
  /// app uploaded them. Off by default: such a copy may be Storage saver.
  public var removesItemsAlreadyInGooglePhotos: Bool
  public var ignoredFolders: [IgnoredFolderLocation]
  public var autoSyncEnabled: Bool
  public var autoStartQueue: Bool
  public var uploadThreads: Int
  public var pairLivePhotos: Bool
  /// iOS only: an edited photo or video also goes up as it came from the camera, since
  /// deleting it from the library deletes the original too.
  public var backsUpUneditedOriginals: Bool
  public var setDateFromFilename: Bool
  public var createAlbumsFromFolders: Bool
  /// iOS only: mirror the photo library's user-created albums into Google Photos.
  /// Folder uploads on both platforms use `createAlbumsFromFolders`.
  public var mirrorPhotoAlbums: Bool
  /// iOS only: photo-library albums whose items cleanup never removes.
  public var protectedAlbumIDs: Set<String>
  /// iOS only: photo-library albums whose items are skipped by backup.
  public var excludedAlbumIDs: Set<String>
  /// iOS only: keeps Favorites on the device during cleanup.
  public var protectsFavorites: Bool
  /// iOS only: automatic cleanup leaves photos opened in the viewer this recently.
  public var keepsRecentlyViewed: RecentlyViewedRetention
  /// When off, uploads wait for an unmetered network: no cellular data on the iPhone, no
  /// Personal Hotspot on the Mac.
  public var uploadsOnMeteredNetworks: Bool
  /// Copies to other accounts wait for the iPhone to charge (the Mac to be plugged in).
  /// Off by default: they run whenever the device is otherwise idle.
  public var copiesOnlyWhileCharging: Bool
  /// Folder and file names, or folder paths, that backed-up folders leave out
  /// (`FolderExclusions`): an editor's project folder inside a watched Movies folder.
  public var backupExclusions: [String]

  public init(
    autoDeleteDelay: AutoDeleteDelay = .never,
    smartDeleteEnabled: Bool = false,
    removesItemsAlreadyInGooglePhotos: Bool = false,
    ignoredFolders: [IgnoredFolderLocation] = [],
    autoSyncEnabled: Bool = true,
    autoStartQueue: Bool = true,
    uploadThreads: Int = 3,
    pairLivePhotos: Bool = true,
    backsUpUneditedOriginals: Bool = true,
    setDateFromFilename: Bool = true,
    createAlbumsFromFolders: Bool = true,
    mirrorPhotoAlbums: Bool = false,
    protectedAlbumIDs: Set<String> = [],
    excludedAlbumIDs: Set<String> = [],
    protectsFavorites: Bool = true,
    keepsRecentlyViewed: RecentlyViewedRetention = .month,
    uploadsOnMeteredNetworks: Bool = true,
    copiesOnlyWhileCharging: Bool = false,
    backupExclusions: [String] = []
  ) {
    self.autoDeleteDelay = autoDeleteDelay
    self.smartDeleteEnabled = smartDeleteEnabled
    self.removesItemsAlreadyInGooglePhotos = removesItemsAlreadyInGooglePhotos
    self.ignoredFolders = ignoredFolders
    self.autoSyncEnabled = autoSyncEnabled
    self.autoStartQueue = autoStartQueue
    self.uploadThreads = uploadThreads
    self.pairLivePhotos = pairLivePhotos
    self.backsUpUneditedOriginals = backsUpUneditedOriginals
    self.setDateFromFilename = setDateFromFilename
    self.createAlbumsFromFolders = createAlbumsFromFolders
    self.mirrorPhotoAlbums = mirrorPhotoAlbums
    self.protectedAlbumIDs = protectedAlbumIDs
    self.excludedAlbumIDs = excludedAlbumIDs
    self.protectsFavorites = protectsFavorites
    self.keepsRecentlyViewed = keepsRecentlyViewed
    self.uploadsOnMeteredNetworks = uploadsOnMeteredNetworks
    self.copiesOnlyWhileCharging = copiesOnlyWhileCharging
    self.backupExclusions = backupExclusions
  }

  public var folderExclusions: FolderExclusions { FolderExclusions(backupExclusions) }

  /// Decoded key by key so a file written before a setting existed still loads.
  ///
  /// The synthesized decoder requires every key, and `AppSettingsStore.load` treats a
  /// decode failure by quarantining the file and returning defaults — so adding a
  /// single new setting would otherwise silently reset every other one, including the
  /// user's protected folders and retention delay.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let fallback = AppSettings()
    self.autoDeleteDelay =
      try container.decodeIfPresent(AutoDeleteDelay.self, forKey: .autoDeleteDelay)
      ?? fallback.autoDeleteDelay
    self.smartDeleteEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .smartDeleteEnabled)
      ?? fallback.smartDeleteEnabled
    self.removesItemsAlreadyInGooglePhotos =
      try container.decodeIfPresent(Bool.self, forKey: .removesItemsAlreadyInGooglePhotos)
      ?? fallback.removesItemsAlreadyInGooglePhotos
    self.ignoredFolders =
      try container.decodeIfPresent([IgnoredFolderLocation].self, forKey: .ignoredFolders)
      ?? fallback.ignoredFolders
    self.autoSyncEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .autoSyncEnabled)
      ?? fallback.autoSyncEnabled
    self.autoStartQueue =
      try container.decodeIfPresent(Bool.self, forKey: .autoStartQueue)
      ?? fallback.autoStartQueue
    self.uploadThreads =
      try container.decodeIfPresent(Int.self, forKey: .uploadThreads)
      ?? fallback.uploadThreads
    self.pairLivePhotos =
      try container.decodeIfPresent(Bool.self, forKey: .pairLivePhotos)
      ?? fallback.pairLivePhotos
    self.backsUpUneditedOriginals =
      try container.decodeIfPresent(Bool.self, forKey: .backsUpUneditedOriginals)
      ?? fallback.backsUpUneditedOriginals
    self.setDateFromFilename =
      try container.decodeIfPresent(Bool.self, forKey: .setDateFromFilename)
      ?? fallback.setDateFromFilename
    self.createAlbumsFromFolders =
      try container.decodeIfPresent(Bool.self, forKey: .createAlbumsFromFolders)
      ?? fallback.createAlbumsFromFolders
    self.mirrorPhotoAlbums =
      try container.decodeIfPresent(Bool.self, forKey: .mirrorPhotoAlbums)
      ?? fallback.mirrorPhotoAlbums
    self.protectedAlbumIDs =
      try container.decodeIfPresent(Set<String>.self, forKey: .protectedAlbumIDs)
      ?? fallback.protectedAlbumIDs
    self.excludedAlbumIDs =
      try container.decodeIfPresent(Set<String>.self, forKey: .excludedAlbumIDs)
      ?? fallback.excludedAlbumIDs
    self.protectsFavorites =
      try container.decodeIfPresent(Bool.self, forKey: .protectsFavorites)
      ?? fallback.protectsFavorites
    self.keepsRecentlyViewed =
      try container.decodeIfPresent(RecentlyViewedRetention.self, forKey: .keepsRecentlyViewed)
      ?? fallback.keepsRecentlyViewed
    self.uploadsOnMeteredNetworks =
      try container.decodeIfPresent(Bool.self, forKey: .uploadsOnMeteredNetworks)
      ?? fallback.uploadsOnMeteredNetworks
    self.copiesOnlyWhileCharging =
      try container.decodeIfPresent(Bool.self, forKey: .copiesOnlyWhileCharging)
      ?? fallback.copiesOnlyWhileCharging
    self.backupExclusions =
      try container.decodeIfPresent([String].self, forKey: .backupExclusions)
      ?? fallback.backupExclusions
  }
}

public enum AppSettingsStore {
  static let didChange = Notification.Name("AppSettingsDidChange")
  private static var settingsURL: URL {
    AppGroupConstants.storageDirectory().appendingPathComponent(AppGroupConstants.settingsFileName)
  }

  public static func load() -> AppSettings {
    load(from: settingsURL)
  }

  /// Returns defaults when the file is absent, unreadable, or no longer matches the
  /// schema. Only a file that fails to decode is moved aside as `.unreadable`; a read
  /// error may be transient (a locked or busy volume), and quarantining then would
  /// discard the user's protected folders and retention delay.
  static func load(from url: URL) -> AppSettings {
    guard FileManager.default.fileExists(atPath: url.path) else { return AppSettings() }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      return AppSettings()
    }
    do {
      return try JSONDecoder().decode(AppSettings.self, from: data)
    } catch {
      quarantine(url)
      return AppSettings()
    }
  }

  /// Moves an undecodable file aside so it is kept for inspection rather than
  /// overwritten by the next save.
  static func quarantine(_ url: URL) {
    let backup = url.appendingPathExtension("unreadable")
    try? FileManager.default.removeItem(at: backup)
    try? FileManager.default.moveItem(at: url, to: backup)
  }

  public static func save(_ settings: AppSettings) throws {
    let data = try JSONEncoder().encode(settings)
    try data.write(to: settingsURL, options: .atomic)
    NotificationCenter.default.post(name: didChange, object: nil)
  }
}

/// Names and phrases shared by the iPhone, Mac, menu bar, and share sheet.
public enum ProductCopy {
  public static let name = "GPhotos"
  public static let googlePhotosURL = URL(string: "https://photos.google.com")!
  public static let originalQuality = "Original quality"
  public static let signOutMessage = "Google Photos credentials will be removed from this device."
  public static let removeAccountConfirmation = "Removes this account from GPhotos. Nothing is deleted from Google Photos."
  public static func idleCopiesFooter(onlyWhileCharging: Bool) -> String {
    #if os(macOS)
      onlyWhileCharging
        ? String(localized: "Copies upload while your Mac is plugged in and idle.")
        : String(localized: "Copies upload while your Mac is idle, after this account's backup.")
    #else
      onlyWhileCharging
        ? String(localized: "Copies upload while your iPhone is charging and idle.")
        : String(localized: "Copies upload while your iPhone is idle, after this account's backup.")
    #endif
  }

  public static func idleCopiesWaiting(onlyWhileCharging: Bool) -> String {
    #if os(macOS)
      onlyWhileCharging ? String(localized: "Waiting until plugged in and idle") : String(localized: "Waiting until idle")
    #else
      onlyWhileCharging ? String(localized: "Waiting until charging and idle") : String(localized: "Waiting until idle")
    #endif
  }
  public static let cleanupExplanation =
    "Only items whose upload to this account was verified are removed — never anything you've protected."

  /// Resolves `^[…](inflect: true)` agreement, which a plain `String(localized:)` leaves as is.
  ///
  /// Agreement takes Foundation several milliseconds a call, and counts are drawn in
  /// titles and on every Years and Months card, so a noun's form is worked out once for
  /// one and once for any other number, then reused with the number at hand.
  public static func inflected(_ value: String.LocalizationValue) -> String {
    let raw = String(localized: value)
    let phrase = InflectedPhrase(raw)
    if let phrase, let noun = inflectedNouns.withLock({ $0[phrase.key] }) { return phrase.text(noun: noun) }
    let resolved = String(AttributedString(localized: value).characters)
    if let phrase, let noun = phrase.noun(in: resolved) {
      inflectedNouns.withLock { $0[phrase.key] = noun }
    }
    return resolved
  }

  private static let inflectedNouns = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
}

/// A string with one `^[<number> <noun>](inflect: true)` in it, taken apart. Anything else
/// (no agreement, several of them, another shape) isn't one, and is resolved by Foundation.
struct InflectedPhrase {
  let prefix: Substring
  let number: Substring
  let noun: Substring
  let suffix: Substring

  private static let opening = "^["
  private static let closing = "](inflect: true)"

  init?(_ raw: String) {
    guard let open = raw.range(of: Self.opening), let close = raw.range(of: Self.closing, range: open.upperBound..<raw.endIndex),
      raw.range(of: Self.opening, range: close.upperBound..<raw.endIndex) == nil
    else { return nil }
    let inside = raw[open.upperBound..<close.lowerBound]
    guard let space = inside.firstIndex(of: " ") else { return nil }
    prefix = raw[..<open.lowerBound]
    number = inside[..<space]
    noun = inside[inside.index(after: space)...]
    suffix = raw[close.upperBound...]
    guard !number.isEmpty, !noun.isEmpty else { return nil }
  }

  /// English, the app's only language, has one form for one and one for every other number.
  var key: String { (number == "1" ? "1 " : "2 ") + noun }

  func text(noun: String) -> String { "\(prefix)\(number) \(noun)\(suffix)" }

  /// The noun as Foundation wrote it in `resolved`, if the rest is where it's expected.
  func noun(in resolved: String) -> String? {
    let lead = "\(prefix)\(number) "
    guard resolved.hasPrefix(lead), resolved.hasSuffix(suffix), resolved.count > lead.count + suffix.count else { return nil }
    return String(resolved.dropFirst(lead.count).dropLast(suffix.count))
  }
}
