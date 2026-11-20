import Foundation

public enum ByteFormat: Sendable {
  public static func string(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 B" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}
