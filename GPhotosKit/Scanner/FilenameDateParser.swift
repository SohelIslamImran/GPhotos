import Foundation

public enum FilenameDateParser {
  private struct Pattern {
    let regex: NSRegularExpression
    let hasTime: Bool
    let isUnixMs: Bool
  }

  private static let patterns: [Pattern] = [
    // 1. YYYYMMDD[_-]HHMMSS - e.g. 20240709_182027.mp4, PXL_20231123_182518628.jpg
    Pattern(
      regex: try! NSRegularExpression(pattern: #"(\d{4})(\d{2})(\d{2})[_-](\d{2})(\d{2})(\d{2})\d*"#),
      hasTime: true,
      isUnixMs: false
    ),
    // 2. YYYY-MM-DD[sep HHMMSS] - e.g. 2022-10-24-150226287.mp4, Screenshot 2026-02-13 093505.png
    Pattern(
      regex: try! NSRegularExpression(pattern: #"(\d{4})-(\d{1,2})-(\d{1,2})(?:[ _-](\d{2})(\d{2})(\d{2})\d*)?"#),
      hasTime: false,
      isUnixMs: false
    ),
    // 3. [non-digit]YYYYMMDDHHMMSS[non-digit] - e.g. lv_7324034615860006160_20240617193045.mp4
    Pattern(
      regex: try! NSRegularExpression(pattern: #"(?:^|[^0-9])(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(?:[^0-9]|$)"#),
      hasTime: true,
      isUnixMs: false
    ),
    // 4. Unix milliseconds - e.g. FaceApp_1658848332262.jpg (covers 2001-2035)
    Pattern(
      regex: try! NSRegularExpression(pattern: #"(?:^|[^0-9])(1\d{12})(?:[^0-9]|$)"#),
      hasTime: true,
      isUnixMs: true
    ),
  ]

  public static func parseDate(from filename: String) -> Date? {
    let base = (filename as NSString).lastPathComponent
    let range = NSRange(location: 0, length: base.utf16.count)

    for p in patterns {
      guard let match = p.regex.firstMatch(in: base, options: [], range: range) else {
        continue
      }

      if p.isUnixMs {
        guard match.numberOfRanges > 1,
          let r1 = Range(match.range(at: 1), in: base),
          let ms = Double(base[r1])
        else {
          continue
        }
        let date = Date(timeIntervalSince1970: ms / 1000.0)
        let year = Calendar.current.component(.year, from: date)
        if year >= 1990 && year <= Calendar.current.component(.year, from: Date()) + 1 {
          return date
        }
        continue
      }

      guard match.numberOfRanges >= 4,
        let yrRange = Range(match.range(at: 1), in: base),
        let moRange = Range(match.range(at: 2), in: base),
        let daRange = Range(match.range(at: 3), in: base),
        let year = Int(base[yrRange]),
        let month = Int(base[moRange]),
        let day = Int(base[daRange])
      else {
        continue
      }

      var hour = 12
      var min = 0
      var sec = 0

      if match.numberOfRanges >= 7 && match.range(at: 4).location != NSNotFound {
        if let hRange = Range(match.range(at: 4), in: base),
          let mRange = Range(match.range(at: 5), in: base),
          let sRange = Range(match.range(at: 6), in: base)
        {
          hour = Int(base[hRange]) ?? 12
          min = Int(base[mRange]) ?? 0
          sec = Int(base[sRange]) ?? 0
        }
      }

      let calendar = Calendar.current
      var comps = DateComponents()
      comps.year = year
      comps.month = month
      comps.day = day
      comps.hour = hour
      comps.minute = min
      comps.second = sec

      // Reject rolled-over dates like month 13 or Feb 30 instead of letting Calendar normalize them.
      guard comps.isValidDate(in: calendar), let date = calendar.date(from: comps) else {
        continue
      }
      if year >= 1990 && year <= calendar.component(.year, from: Date()) + 1 {
        return date
      }
    }
    return nil
  }
}
