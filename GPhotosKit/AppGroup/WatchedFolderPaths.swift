import Foundation

/// Path rules for the Mac app's watched folders. They live in GPhotosKit so the
/// macOS test target, which links only the framework, can exercise them.
public enum WatchedFolderPaths {
  /// Bundles whose contents are owned by another app. The scanner never descends into
  /// packages, so churn inside one (a Photos library in ~/Pictures) cannot change
  /// what a scan finds.
  static let packageExtensions: Set<String> = [
    "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "lrlibrary",
    "lrdata", "imovielibrary", "fcpbundle", "app", "bundle", "framework", "download",
  ]

  /// Whether `path` is `root` or lies inside it. Compared case-insensitively, as on
  /// the default APFS volume.
  public static func isPath(_ path: String, inside root: String) -> Bool {
    let path = trimmingTrailingSlash(path)
    let root = trimmingTrailingSlash(root)
    if path.caseInsensitiveCompare(root) == .orderedSame { return true }
    return path.lowercased().hasPrefix(root.lowercased() + "/")
  }

  /// Whether a file-system event at `path` can change what a scan of `root` finds.
  /// Hidden items (including the app's own `.gphotos-delete-` tombstones), package
  /// contents, in-progress `.partial` copies and non-media files are ignored, because
  /// each would otherwise trigger a full rescan.
  public static func isRelevantChange(path: String, root: String, isFile: Bool) -> Bool {
    let trimmedRoot = trimmingTrailingSlash(root)
    let trimmedPath = trimmingTrailingSlash(path)
    let components: [Substring]
    if isPath(trimmedPath, inside: trimmedRoot) {
      components = trimmedPath.dropFirst(trimmedRoot.count).split(separator: "/")
    } else {
      components = trimmedPath.split(separator: "/").suffix(1)
    }
    for component in components {
      if component.hasPrefix(".") { return false }
      let ext = (String(component) as NSString).pathExtension.lowercased()
      if ext == "partial" || packageExtensions.contains(ext) { return false }
    }
    if isFile, let name = components.last {
      return SupportedMediaFormats.isSupported(filename: String(name))
    }
    return true
  }

  /// `/var` and `/tmp` are symbolic links into `/private`, and the system hands out
  /// paths in both spellings; this picks the `/private` one so they compare equal
  /// without touching the file system.
  public static func privatePrefixed(_ path: String) -> String {
    for link in ["/var", "/tmp"] where path == link || path.hasPrefix(link + "/") {
      return "/private" + path
    }
    return path
  }

  private static func trimmingTrailingSlash(_ path: String) -> String {
    guard path.count > 1, path.hasSuffix("/") else { return path }
    return String(path.dropLast())
  }
}
