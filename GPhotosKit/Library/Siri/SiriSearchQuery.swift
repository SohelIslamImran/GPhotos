import Foundation

/// A spoken or typed request ("videos of the dog from July 2024") split into what the index
/// searches for and the filters the words name: a period, videos only, favorites only.
public struct SiriSearchQuery: Sendable, Equatable {
  /// Words the index matches against labels, text, places and names.
  public var terms: [String]
  public var period: Range<Date>?
  public var videosOnly = false
  public var favoritesOnly = false

  public var isEmpty: Bool { terms.isEmpty && period == nil && !videosOnly && !favoritesOnly }

  public init(terms: [String], period: Range<Date>? = nil, videosOnly: Bool = false, favoritesOnly: Bool = false) {
    self.terms = terms
    self.period = period
    self.videosOnly = videosOnly
    self.favoritesOnly = favoritesOnly
  }

  public init(_ text: String, now: Date = Date(), calendar: Calendar = .current) {
    let words = text.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
      .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
      .filter { !$0.isEmpty }
    var terms: [String] = []
    var month: Int?
    var year: Int?
    var period: Range<Date>?
    let months = Self.monthNames(calendar: calendar)

    var index = 0
    while index < words.count {
      let word = words[index]
      let next = index + 1 < words.count ? words[index + 1] : nil
      if let relative = next.flatMap({ Self.relativeUnit($0) }), word == "this" || word == "last" {
        period = Self.period(relative, offset: word == "last" ? -1 : 0, now: now, calendar: calendar)
        index += 2
        continue
      }
      if word == "today" || word == "yesterday" {
        let start = calendar.startOfDay(for: now)
        let day = word == "today" ? start : calendar.date(byAdding: .day, value: -1, to: start) ?? start
        period = day..<(calendar.date(byAdding: .day, value: 1, to: day) ?? day)
      } else if let number = Int(word), (1900...2100).contains(number), word.count == 4 {
        year = number
      } else if let found = months[word] {
        month = found
      } else if Self.videoWords.contains(word) {
        videosOnly = true
      } else if Self.favoriteWords.contains(word) {
        favoritesOnly = true
      } else if !Self.stopWords.contains(word) {
        terms.append(word)
      }
      index += 1
    }

    if let year {
      var parts = DateComponents(year: year, month: month ?? 1, day: 1)
      parts.calendar = calendar
      if let start = calendar.date(from: parts),
        let end = calendar.date(byAdding: month == nil ? .year : .month, value: 1, to: start)
      {
        period = start..<end
      }
    } else if let month {
      // A month alone is its latest occurrence: "photos from March" in January is last March.
      let thisYear = calendar.component(.year, from: now)
      let currentMonth = calendar.component(.month, from: now)
      let year = month > currentMonth ? thisYear - 1 : thisYear
      if let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
        let end = calendar.date(byAdding: .month, value: 1, to: start)
      {
        period = start..<end
      }
    }
    self.terms = terms
    self.period = period
  }

  private static func relativeUnit(_ word: String) -> Calendar.Component? {
    switch word {
    case "week": .weekOfYear
    case "month": .month
    case "year": .year
    default: nil
    }
  }

  private static func period(_ unit: Calendar.Component, offset: Int, now: Date, calendar: Calendar) -> Range<Date>? {
    guard let current = calendar.dateInterval(of: unit, for: now),
      let start = calendar.date(byAdding: unit, value: offset, to: current.start),
      let end = calendar.date(byAdding: unit, value: 1, to: start)
    else { return nil }
    return start..<end
  }

  /// English month names and the current language's, full and short ("jul").
  private static func monthNames(calendar: Calendar) -> [String: Int] {
    var names: [String: Int] = [:]
    for locale in [Locale(identifier: "en_US"), calendar.locale ?? .current] {
      var localized = Calendar(identifier: .gregorian)
      localized.locale = locale
      for (index, name) in localized.monthSymbols.enumerated() { names[name.lowercased()] = index + 1 }
      for (index, name) in localized.shortMonthSymbols.enumerated() {
        let short = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        // "may" is both; short names that are also common words are left to the full names.
        if short.count >= 3, names[short] == nil { names[short] = index + 1 }
      }
    }
    return names
  }

  private static let videoWords: Set<String> = ["video", "videos", "movie", "movies", "clip", "clips", "footage"]
  private static let favoriteWords: Set<String> = [
    "favorite", "favorites", "favourite", "favourites", "starred", "loved", "liked",
  ]
  /// Words that name what to show rather than what's in it.
  private static let stopWords: Set<String> = [
    "a", "about", "all", "an", "and", "any", "are", "at", "by", "can", "did", "do", "every", "find", "for", "from",
    "gallery", "get", "gphotos", "had", "have", "i", "i'm", "image", "images", "in", "is", "it", "its",
    "look", "me", "mine", "my", "of", "on", "or", "our", "photo", "photos", "pic", "pics", "picture",
    "pictures", "please", "search", "see", "shot", "shots", "show", "some", "sync", "taken", "that", "the", "their",
    "them", "these", "this", "those", "to", "took", "was", "we", "were", "where", "which", "while", "with", "you",
    "your",
  ]
}
