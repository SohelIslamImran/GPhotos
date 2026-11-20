import Foundation

/// Month sections over a date-ordered list of items, built once per fetch so the month
/// at any index (the date label while scrolling, the Months and Years views) is a binary
/// search instead of a date calculation per frame.
public struct TimelineIndex: Equatable, Sendable {
  public struct Section: Equatable, Sendable, Identifiable {
    public let start: Date
    public let range: Range<Int>
    public var id: Int { range.lowerBound }
  }

  public let months: [Section]

  public init(months: [Section] = []) {
    self.months = months
  }

  /// Groups consecutive items by calendar month. Items without a date join the month
  /// before them, so the sections always cover every index once.
  public static func build(count: Int, calendar: Calendar = .current, date: (Int) -> Date?) -> TimelineIndex {
    var months: [Section] = []
    var current: DateInterval?
    var sectionStart = 0
    for index in 0..<count {
      guard let value = date(index) else { continue }
      if let interval = current, interval.start <= value, value < interval.end { continue }
      guard let interval = calendar.dateInterval(of: .month, for: value) else { continue }
      if let previous = current, index > sectionStart {
        months.append(Section(start: previous.start, range: sectionStart..<index))
        sectionStart = index
      }
      current = interval
    }
    if let current, sectionStart < count {
      months.append(Section(start: current.start, range: sectionStart..<count))
    }
    return TimelineIndex(months: months)
  }

  public func month(containing index: Int) -> Section? {
    var low = 0
    var high = months.count - 1
    while low <= high {
      let mid = (low + high) / 2
      let range = months[mid].range
      if index < range.lowerBound {
        high = mid - 1
      } else if index >= range.upperBound {
        low = mid + 1
      } else {
        return months[mid]
      }
    }
    return nil
  }

  /// Months merged into years, in the list's order.
  public func years(calendar: Calendar = .current) -> [Section] {
    var years: [Section] = []
    for month in months {
      let year = calendar.dateInterval(of: .year, for: month.start)?.start ?? month.start
      if let last = years.last, last.start == year {
        years[years.count - 1] = Section(start: year, range: last.range.lowerBound..<month.range.upperBound)
      } else {
        years.append(Section(start: year, range: month.range))
      }
    }
    return years
  }
}
