import Foundation

public enum AppGroupConstants {
  /// Read from the host bundle so the app and its extension agree. macOS uses the
  /// Team-ID-prefixed form, which needs no provisioning profile (a profile that doesn't
  /// authorize a `group.` App Group invalidates the app's entitlements and with them its
  /// keychain access); iOS uses the `group.` form.
  public static let identifier =
    Bundle.main.object(forInfoDictionaryKey: "GPhotosAppGroupIdentifier") as? String
    ?? "group.org.gphotosapp.gphotos"
  public static let keychainService = "org.gphotosapp.gphotos.credentials"

  public static let sharedQueueFileName = "pending-uploads.json"
  public static let settingsFileName = "app-settings.json"
  public static let incomingFolderName = "Incoming"

  public static let shareItemsAddedNotification = "org.gphotosapp.gphotos.shareItemsAdded"

  private static let resolvedStorageDirectory: URL = {
    let fileManager = FileManager.default
    if let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier),
      isWritable(container)
    {
      return container.standardizedFileURL
    }
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    let directory = base.appendingPathComponent("GPhotos", isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.standardizedFileURL
  }()

  /// `containerURL` returns a path whenever the entitlement exists, even if the
  /// container cannot actually be written. Verifying first keeps a broken App Group
  /// from silently discarding every manifest write.
  private static func isWritable(_ directory: URL) -> Bool {
    let fileManager = FileManager.default
    guard (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
      return false
    }
    let probe = directory.appendingPathComponent(".storage-probe")
    do {
      try Data().write(to: probe)
    } catch {
      return isOutOfSpace(error)
    }
    try? fileManager.removeItem(at: probe)
    return true
  }

  /// A full disk is no reason to leave the container: the private one would start from an
  /// empty manifest, and every photo would look new.
  static func isOutOfSpace(_ error: any Error) -> Bool {
    let error = error as NSError
    if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
    if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) || error.code == Int(EDQUOT) { return true }
    return error.underlyingErrors.contains(where: isOutOfSpace)
  }

  public static func storageDirectory() -> URL {
    resolvedStorageDirectory
  }

  /// Whether `storageDirectory()` really is the App Group container.
  ///
  /// A sandboxed process whose group is unreachable falls back to its own private
  /// container, which is writable and therefore indistinguishable by path alone. A
  /// share extension must check this: staging into a private container would report
  /// success while the host app never sees the files.
  ///
  /// The group is unreachable when the App Group is not enabled for the running
  /// platform in the Developer portal. App Groups cannot be created automatically, so
  /// a build made before that step lands here rather than failing to sign.
  public static func isUsingSharedContainer() -> Bool {
    resolvedStorageDirectory
      == FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: identifier)?
      .standardizedFileURL
  }
}
