import Foundation

/// Pure logic for splitting albums that exceed Google Photos' 20,000-item cap.
///
/// Albums exceeding the limit roll over into
/// `<Name> (2)`, `<Name> (3)`, etc.
public enum AlbumRollover: Sendable {
  /// Maximum number of items in a single Google Photos album.
  public static let albumLimit = 20_000

  /// Returns the rollover name for a 1-based part index.
  /// - Part 1: `"Album"`
  /// - Part 2: `"Album (2)"`
  /// - Part 3: `"Album (3)"`
  public static func partName(for baseName: String, part: Int) -> String {
    guard part > 1 else { return baseName }
    return "\(baseName) (\(part))"
  }

  /// Returns the rollover album name for a 0-based item index within an album.
  public static func albumName(for baseName: String, itemIndex: Int) -> String {
    guard itemIndex >= 0 else { return baseName }
    let part = (itemIndex / albumLimit) + 1
    return partName(for: baseName, part: part)
  }

  /// A planned slice of media to add to a specific rollover album.
  public struct AdditionSlice: Equatable, Sendable {
    public let albumName: String
    public let range: Range<Int>
    public let newCount: Int

    public init(albumName: String, range: Range<Int>, newCount: Int) {
      self.albumName = albumName
      self.range = range
      self.newCount = newCount
    }
  }

  /// Plans additions across rollover albums given the items to add and a lookup for
  /// each part's current tracked count.
  public static func planAdditions(
    baseName: String,
    itemCount: Int,
    currentCountForName: (String) -> Int
  ) -> [AdditionSlice] {
    guard itemCount > 0 else { return [] }
    var slices: [AdditionSlice] = []
    var part = 1
    var offset = 0

    while offset < itemCount {
      let name = partName(for: baseName, part: part)
      let count = currentCountForName(name)
      if count >= albumLimit {
        part += 1
        continue
      }
      let capacity = albumLimit - count
      let take = min(capacity, itemCount - offset)
      let range = offset..<(offset + take)
      slices.append(AdditionSlice(albumName: name, range: range, newCount: count + take))
      offset += take
      part += 1
    }

    return slices
  }
}
