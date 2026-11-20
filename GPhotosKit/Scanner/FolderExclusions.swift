import Foundation

/// What backed-up folders leave out, from the user's rules. A name ("CapCut", "Cache*",
/// "*.tmp") leaves out every folder or file with that name, at any depth below a backed-up
/// folder; `*` and `?` match as in Finder. A path ("/Users/me/Movies/CapCut" or
/// "~/Movies/CapCut") leaves out that folder and everything in it. Case never matters.
public struct FolderExclusions: Sendable, Hashable {
  public static let none = FolderExclusions([])

  private let names: [String]
  private let paths: [[String]]

  public init(_ rules: [String]) {
    var names: [String] = []
    var paths: [[String]] = []
    for rule in rules {
      let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
        let path = (NSString(string: trimmed).expandingTildeInPath as NSString).standardizingPath
        let components = Self.components(path)
        if !components.isEmpty { paths.append(components) }
      } else {
        // A trailing slash ("CapCut/") still means the folder's name.
        let name = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !name.isEmpty, !name.contains("/") { names.append(name.lowercased()) }
      }
    }
    self.names = names
    self.paths = paths
  }

  /// The rules as one stable string, for caches kept across launches.
  public var key: String {
    (names.map { "n:" + $0 } + paths.map { "p:/" + $0.joined(separator: "/").lowercased() }).sorted().joined(
      separator: "\n")
  }

  public var isEmpty: Bool { names.isEmpty && paths.isEmpty }

  /// A folder or file named `name` is left out wherever it is.
  public func excludes(name: String) -> Bool {
    guard !names.isEmpty else { return false }
    let name = name.lowercased()
    return names.contains { fnmatch($0, name, 0) == 0 }
  }

  /// The item at `path` is left out by a path rule: it is that folder or inside it.
  public func excludes(path: String) -> Bool {
    guard !paths.isEmpty else { return false }
    let components = Self.components((path as NSString).standardizingPath)
    return paths.contains { rule in
      components.count >= rule.count
        && zip(components, rule).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
    }
  }

  /// Whether `url`, somewhere below the backed-up folder `root`, is left out by its own
  /// name, the name of a folder between it and `root`, or a path rule.
  public func excludes(_ url: URL, below root: URL) -> Bool {
    guard !isEmpty else { return false }
    if excludes(path: url.path) { return true }
    let base = Self.components(root.standardizedFileURL.path)
    let full = Self.components(url.standardizedFileURL.path)
    guard full.count > base.count,
      zip(full, base).allSatisfy({ $0.caseInsensitiveCompare($1) == .orderedSame })
    else { return false }
    return full.dropFirst(base.count).contains { excludes(name: $0) }
  }

  private static func components(_ path: String) -> [String] {
    path.split(separator: "/").map(String.init)
  }
}
