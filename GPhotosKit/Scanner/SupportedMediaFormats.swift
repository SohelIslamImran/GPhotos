import Foundation
import ImageIO

public enum SupportedMediaFormats {
  /// Camera RAW formats Google Photos accepts, including CR3, RAF, RW2, and DNG.
  public static let rawExtensions: Set<String> = [
    "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "k25", "kdc", "mrw",
    "nef", "orf", "pef", "raf", "raw", "rw2", "sr2", "srf", "x3f",
  ]

  public static let photoExtensions: Set<String> = rawExtensions.union([
    "avif", "bmp", "gif", "heic", "heif", "ico",
    "jpg", "jpeg", "png", "tif", "tiff", "webp",
  ])

  public static let videoExtensions: Set<String> = [
    "3gp", "3g2", "asf", "avi", "divx",
    "m2t", "m2ts", "m4v", "mkv", "mmv",
    "mod", "mov", "mp4", "mpg", "mpeg",
    "mts", "tod", "wmv", "ts", "webm",
  ]

  public static let allSupportedExtensions: Set<String> = photoExtensions.union(videoExtensions)

  public static func isSupported(fileURL: URL) -> Bool {
    guard isSupported(filename: fileURL.lastPathComponent) else { return false }
    let ext = fileURL.pathExtension.lowercased()
    return !["ts", "mod", "raw"].contains(ext) || isMediaContent(fileURL: fileURL)
  }

  /// Bounded container inspection, without decoding a full photo or loading a video.
  public static func isMediaContent(fileURL: URL) -> Bool {
    let ext = fileURL.pathExtension.lowercased()
    if photoExtensions.contains(ext) {
      let options = [kCGImageSourceShouldCache: false] as CFDictionary
      if let source = CGImageSourceCreateWithURL(fileURL as CFURL, options), CGImageSourceGetCount(source) > 0,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
        let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
        width.intValue > 0, height.intValue > 0
      {
        return true
      }
      // A new camera's RAW can be valid before this OS has a decoder for it.
      guard rawExtensions.contains(ext), let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
      defer { try? handle.close() }
      guard let header = try? handle.read(upToCount: 32) else { return false }
      return header.starts(with: [0x49, 0x49, 0x2a, 0]) || header.starts(with: [0x4d, 0x4d, 0, 0x2a])
        || header.starts(with: [0x49, 0x49, 0x2b, 0]) || header.starts(with: [0x4d, 0x4d, 0, 0x2b])
        || header.starts(with: Data("FUJIFILMCCD-RAW".utf8)) || header.starts(with: [0, 0x4d, 0x52, 0x4d])
        || (header.count >= 14 && String(decoding: header.dropFirst(6).prefix(8), as: UTF8.self) == "HEAPCCDR")
        || (header.count >= 12 && String(decoding: header.dropFirst(4).prefix(8), as: UTF8.self) == "ftypcrx ")

    }
    guard videoExtensions.contains(ext), let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 4096) else { return false }
    return isVideoHeader(data, extension: ext)
  }

  static func isVideoHeader(_ data: Data, extension ext: String) -> Bool {
    let bytes = [UInt8](data)
    if bytes.isEmpty || bytes.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }) { return false }
    func starts(_ prefix: [UInt8]) -> Bool { bytes.starts(with: prefix) }
    func text(_ range: Range<Int>) -> String {
      guard range.upperBound <= bytes.count else { return "" }
      return String(decoding: bytes[range], as: UTF8.self)
    }
    if text(4..<8) == "ftyp", ["M4A ", "M4B ", "M4P "].contains(text(8..<12)) { return false }
    if ["ts", "mts", "m2ts", "m2t", "mod", "tod", "mmv"].contains(ext) {
      for (stride, offset) in [(188, 0), (192, 4), (204, 0)] {
        if bytes.count >= offset + stride * 2 + 4,
          (0..<3).allSatisfy({ bytes[offset + $0 * stride] == 0x47 && bytes[offset + $0 * stride + 3] & 0x30 != 0 })
        {
          return true
        }
      }
      if ext != "mod" { return false }
    }
    switch ext {
    case "avi", "divx": return text(0..<4) == "RIFF" && text(8..<12) == "AVI "
    case "mkv", "webm": return starts([0x1a, 0x45, 0xdf, 0xa3])
    case "wmv", "asf": return starts([0x30, 0x26, 0xb2, 0x75, 0x8e, 0x66, 0xcf, 0x11])
    case "mpg", "mpeg", "mod", "tod", "m4v":
      if starts([0, 0, 1]), bytes.count > 3, [0xba, 0xb3, 0xb0].contains(bytes[3]) { return true }
      return ["ftyp", "moov", "mdat"].contains(text(4..<8))
    default: return ["ftyp", "moov", "mdat", "wide", "free", "skip"].contains(text(4..<8))
    }
  }

  public static func isSupported(filename: String) -> Bool {
    let ext = (filename as NSString).pathExtension.lowercased()
    return allSupportedExtensions.contains(ext)
  }

  public static func isPhoto(filename: String) -> Bool {
    let ext = (filename as NSString).pathExtension.lowercased()
    return photoExtensions.contains(ext)
  }

  public static func isVideo(filename: String) -> Bool {
    let ext = (filename as NSString).pathExtension.lowercased()
    return videoExtensions.contains(ext)
  }
}
