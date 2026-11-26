import Accelerate
import CoreLocation
import Foundation
import MapKit
import os

/// Similar-photo groups (bursts, retakes, near duplicates). Similar shots are taken close
/// together, so each item is compared only with the next few taken within a short window:
/// linear in library size instead of quadratic.
enum SimilarityGrouping {
  static func groups(
    count: Int, date: (Int) -> Date, window: TimeInterval = 120, maxNeighbors: Int = 24, threshold: Double = 0.3,
    distance: (Int, Int) -> Double?
  ) -> [[Int]] {
    var parent = Array(0..<count)
    func root(_ index: Int) -> Int {
      var index = index
      while parent[index] != index {
        parent[index] = parent[parent[index]]
        index = parent[index]
      }
      return index
    }
    for index in 0..<count {
      var other = index + 1
      while other < count, other - index <= maxNeighbors, date(other).timeIntervalSince(date(index)) <= window {
        if let value = distance(index, other), value < threshold {
          let (a, b) = (root(index), root(other))
          if a != b { parent[b] = a }
        }
        other += 1
      }
    }
    var groups: [Int: [Int]] = [:]
    for index in 0..<count { groups[root(index), default: []].append(index) }
    return groups.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
  }
}

/// Conservative average-link matching of aligned crops. A single close sample cannot
/// bridge otherwise unrelated people; ambiguous faces wait for another pass.
enum FaceClustering {
  struct Result: Equatable {
    var assignments: [Int: Int64]
    var nextPersonID: Int64
    var merges: [Int64: Int64] = [:]
  }

  static func assign(
    existing: [(person: Int64, faces: [Int])], unassigned: [Int], threshold: Double = 0.40, nextPersonID: Int64,
    itemID: (Int) -> String = { String($0) }, names: [Int64: String] = [:],
    buckets: ((Int) -> [Int64])? = nil, allowsMerging: Bool = true,
    distance: (Int, Int) -> Double?
  ) -> Result {
    var groups = existing.sorted { $0.person < $1.person }
    var result = Result(assignments: [:], nextPersonID: nextPersonID)
    var photos = groups.map { Set($0.faces.map(itemID)) }
    var lookup: [Int64: [Int]] = [:]
    func register(_ index: Int) {
      guard let buckets else { return }
      for face in groups[index].faces {
        for (table, key) in buckets(face).enumerated() {
          let bucket = Int64(table) * 1024 + key
          if var list = lookup[bucket] {
            guard list.count < 128, !list.contains(index) else { continue }
            list.append(index)
            lookup[bucket] = list
          } else {
            lookup[bucket] = [index]
          }
        }
      }
    }
    for index in groups.indices { register(index) }
    func candidates(_ faces: [Int]) -> [Int] {
      guard let buckets else { return Array(groups.indices) }
      var votes: [Int: Int] = [:]
      for face in faces {
        for (table, key) in buckets(face).enumerated() {
          let tableOffset = Int64(table) * 1024
          for bit in -1..<10 {
            let neighbor = bit < 0 ? key : key ^ (1 << bit)
            guard let entries = lookup[tableOffset + neighbor] else { continue }
            for index in entries where !groups[index].faces.isEmpty {
              votes[index, default: 0] += 1
            }
          }
        }
      }
      return votes.keys.sorted { votes[$0] == votes[$1] ? $0 < $1 : votes[$0]! > votes[$1]! }.prefix(128).map { $0 }
    }
    func linkage(_ a: [Int], _ b: [Int]) -> Double? {
      var sum = 0.0
      var count = 0
      for first in a.prefix(5) {
        for second in b.prefix(5) {
          guard let value = distance(first, second), value.isFinite, value < threshold + 0.16 else { return nil }
          sum += value
          count += 1
        }
      }
      return count > 0 ? sum / Double(count) : nil
    }
    // Candidate retrieval is bounded before this pass. Reconcile only nearby groups,
    // with a fixed comparison budget so a crowd cannot trigger quadratic work.
    var comparisons = 0
    merging: for a in groups.indices where allowsMerging && !groups[a].faces.isEmpty {
      for b in candidates(groups[a].faces) where b > a && !groups[b].faces.isEmpty && !groups[a].faces.isEmpty {
        guard comparisons < 8_192 else { break merging }
        comparisons += 1
        guard photos[a].isDisjoint(with: photos[b]),
          names[groups[a].person] == nil || names[groups[b].person] == nil,
          let score = linkage(groups[a].faces, groups[b].faces), score < threshold - 0.08
        else { continue }
        let winner = names[groups[b].person] != nil && names[groups[a].person] == nil ? b : a
        let loser = winner == a ? b : a
        result.merges[groups[loser].person] = groups[winner].person
        groups[winner].faces = Array((groups[winner].faces + groups[loser].faces).prefix(5))
        photos[winner].formUnion(photos[loser])
        groups[loser].faces = []
        register(winner)
      }
    }
    for face in unassigned {
      let photo = itemID(face)
      var matches: [(index: Int, score: Double)] = []
      var uncertain = false
      for index in candidates([face]) where !groups[index].faces.isEmpty && !photos[index].contains(photo) {
        if let score = linkage([face], groups[index].faces) {
          if score < threshold + 0.12 { uncertain = true }
          // An average over three or more photos of someone is steady: on a real library
          // strangers stayed 0.55 or more from it, while the same person across years
          // reached 0.5 to 0.6. One photo alone is matched more strictly.
          let references = groups[index].faces.count
          let cutoff = references == 1 ? threshold - 0.08 : references >= 3 ? threshold + 0.08 : threshold
          if score < cutoff { matches.append((index, score)) }
        }
      }
      matches.sort { $0.score == $1.score ? $0.index < $1.index : $0.score < $1.score }
      if let best = matches.first {
        guard matches.count == 1 || matches[1].score - best.score >= 0.06 else { continue }
        result.assignments[face] = groups[best.index].person
        photos[best.index].insert(photo)
        if groups[best.index].faces.count < 5 {
          groups[best.index].faces.append(face)
          register(best.index)
        }
      } else {
        guard !uncertain else { continue }
        result.assignments[face] = result.nextPersonID
        groups.append((result.nextPersonID, [face]))
        photos.append([photo])
        register(groups.count - 1)
        result.nextPersonID += 1
      }
    }
    return result
  }

  private struct ProjectionTerm: Sendable {
    let index: Int
    let sign: Float
  }

  /// Cached LCG projection tables by vector dimension so repeated bucket calls don't rerun
  /// 1,280 LCG steps per face while preserving exact bit compatibility with stored `k0..k3`.
  private static let projectionTables = OSAllocatedUnfairLock<[Int: [ProjectionTerm]]>(initialState: [:])

  private static func projectionTable(dimension: Int) -> [ProjectionTerm] {
    if let cached = projectionTables.withLock({ $0[dimension] }) { return cached }
    var state: UInt64 = 0x4d59_5df4_d0f3_3173
    func random() -> UInt64 {
      state = state &* 6_364_136_223_846_793_005 &+ 1
      return state >> 32
    }
    var terms: [ProjectionTerm] = []
    terms.reserveCapacity(4 * 10 * 32)
    for _ in 0..<(4 * 10 * 32) {
      let index = Int(random() % UInt64(dimension))
      let sign: Float = random() & 1 == 0 ? -1 : 1
      terms.append(ProjectionTerm(index: index, sign: sign))
    }
    let built = terms
    projectionTables.withLock { $0[dimension] = built }
    return built
  }

  /// Four independent locality-sensitive hashes shortlist candidates in SQLite, keeping
  /// vectors bounded even when the library has hundreds of thousands of faces.
  static func buckets(_ data: Data) -> [Int64] {
    let floatCount = data.count / MemoryLayout<Float>.size
    guard floatCount > 0 else { return [] }
    var vector = [Float](repeating: 0, count: floatCount)
    _ = vector.withUnsafeMutableBytes { buffer in
      data.copyBytes(to: buffer, count: floatCount * MemoryLayout<Float>.size)
    }
    guard vector.allSatisfy(\.isFinite) else { return [] }
    let terms = projectionTable(dimension: floatCount)
    var keys: [Int64] = []
    keys.reserveCapacity(4)
    var offset = 0
    for _ in 0..<4 {
      var key: Int64 = 0
      for bit in 0..<10 {
        var projection: Float = 0
        for _ in 0..<32 {
          let term = terms[offset]
          projection += vector[term.index] * term.sign
          offset += 1
        }
        if projection >= 0 { key |= 1 << bit }
      }
      keys.append(key)
    }
    return keys
  }
}

/// On This Day and trips, from dates and places across the merged library.
enum MemoryFinder {
  struct Moment: Sendable, Equatable {
    let date: Date
    let latitude: Double?
    let longitude: Double?
  }

  private struct DayWindow {
    let year: Int
    let start: TimeInterval
    let end: TimeInterval
  }

  /// Indices of items taken on today's month and day in earlier years, grouped by year,
  /// most recent year first.
  static func onThisDay(_ moments: [Moment], today: Date, calendar: Calendar = .current) -> [(year: Int, indices: [Int])] {
    let target = calendar.dateComponents([.month, .day, .year], from: today)
    guard let targetMonth = target.month, let targetDay = target.day, let targetYear = target.year else { return [] }
    guard let targetYearStart = calendar.date(from: DateComponents(year: targetYear, month: 1, day: 1)) else { return [] }
    let targetYearCutoff = targetYearStart.timeIntervalSince1970
    // Precompute the exact local-day timestamp range for each prior year once instead of
    // running `Calendar.dateComponents` on 100k moments.
    let earliestCapYear = max(1, targetYear - 200)
    var earliestTimestamp = targetYearCutoff
    for moment in moments {
      let t = moment.date.timeIntervalSince1970
      if t < earliestTimestamp { earliestTimestamp = t }
    }
    guard earliestTimestamp < targetYearCutoff else { return [] }
    let minYear = max(earliestCapYear, calendar.component(.year, from: Date(timeIntervalSince1970: earliestTimestamp)))
    var windows: [DayWindow] = []
    windows.reserveCapacity(max(0, targetYear - minYear))
    for year in minYear..<targetYear {
      guard let dayDate = calendar.date(from: DateComponents(year: year, month: targetMonth, day: targetDay)) else {
        continue
      }
      // Reject non-leap-year rollovers (e.g., Feb 29 -> Mar 1).
      let check = calendar.dateComponents([.month, .day, .year], from: dayDate)
      guard check.year == year, check.month == targetMonth, check.day == targetDay else { continue }
      let start = calendar.startOfDay(for: dayDate)
      guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
      windows.append(DayWindow(year: year, start: start.timeIntervalSince1970, end: end.timeIntervalSince1970))
    }
    let minWindowStart = windows.first?.start ?? .infinity
    let maxWindowEnd = windows.last?.end ?? -.infinity
    let capCutoff =
      calendar.date(from: DateComponents(year: earliestCapYear, month: 1, day: 1))?.timeIntervalSince1970 ?? -.infinity

    var byYear: [Int: [Int]] = [:]
    var lastWindowIndex = 0
    for (index, moment) in moments.enumerated() {
      let t = moment.date.timeIntervalSince1970
      if t >= targetYearCutoff { continue }
      if t < capCutoff {
        let parts = calendar.dateComponents([.month, .day, .year], from: moment.date)
        if parts.month == targetMonth, parts.day == targetDay, let year = parts.year, year < targetYear {
          byYear[year, default: []].append(index)
        }
        continue
      }
      guard t >= minWindowStart, t < maxWindowEnd else { continue }
      // Timeline moments are mostly date-ordered, so check the last matched window first.
      if lastWindowIndex < windows.count, t >= windows[lastWindowIndex].start, t < windows[lastWindowIndex].end {
        byYear[windows[lastWindowIndex].year, default: []].append(index)
        continue
      }
      var low = 0
      var high = windows.count - 1
      while low <= high {
        let mid = (low + high) / 2
        let window = windows[mid]
        if t < window.start {
          high = mid - 1
        } else if t >= window.end {
          low = mid + 1
        } else {
          lastWindowIndex = mid
          byYear[window.year, default: []].append(index)
          break
        }
      }
    }
    return byYear.sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
  }

  /// Runs of items far from home on nearby days. Home is the most common place.
  static func trips(
    _ moments: [Moment], minimumItems: Int = 12, awayKilometres: Double = 100, maximumGapDays: Double = 2
  ) -> [[Int]] {
    var located: [Int] = []
    var cells: [Int64: Int] = [:]
    for index in moments.indices {
      let moment = moments[index]
      guard let lat = moment.latitude, let lon = moment.longitude else { continue }
      located.append(index)
      cells[cell(latitude: lat, longitude: lon), default: 0] += 1
    }
    guard located.count >= minimumItems else { return [] }
    guard let home = cells.max(by: { $0.value < $1.value })?.key,
      let homeIndex = located.first(where: {
        let m = moments[$0]
        return cell(latitude: m.latitude ?? 0, longitude: m.longitude ?? 0) == home
      })
    else { return [] }
    let homeMoment = moments[homeIndex]
    let homeLat = homeMoment.latitude ?? 0
    let homeLon = homeMoment.longitude ?? 0
    // Exact spherical bounds (R * pi / 180 ~= 111.195 km/deg): skip trig for clear home or far points.
    let minAwayLatDeg = awayKilometres / 111.19
    let maxNearManhatDeg = awayKilometres / 111.20

    var away: [Int] = []
    var isSorted = true
    var previousDate: Date?
    for index in located {
      let moment = moments[index]
      guard let lat = moment.latitude, let lon = moment.longitude else { continue }
      let dLat = abs(lat - homeLat)
      let isAway: Bool
      if dLat > minAwayLatDeg {
        isAway = true
      } else {
        var dLon = abs(lon - homeLon)
        if dLon > 180 { dLon = 360 - dLon }
        if dLat + dLon < maxNearManhatDeg {
          isAway = false
        } else {
          isAway = kilometres(moment, homeMoment) > awayKilometres
        }
      }
      guard isAway else { continue }
      if let previousDate, moment.date < previousDate { isSorted = false }
      previousDate = moment.date
      away.append(index)
    }
    if !isSorted { away.sort { moments[$0].date < moments[$1].date } }
    var trips: [[Int]] = []
    var current: [Int] = []
    for index in away {
      if let last = current.last, moments[index].date.timeIntervalSince(moments[last].date) > maximumGapDays * 86_400 {
        if current.count >= minimumItems { trips.append(current) }
        current = []
      }
      current.append(index)
    }
    if current.count >= minimumItems { trips.append(current) }
    return trips.reversed()
  }

  private static func cell(latitude: Double, longitude: Double) -> Int64 {
    let lat = Int64(Int32((latitude * 2).rounded()))
    let lon = Int64(Int32((longitude * 2).rounded()))
    return (lat << 32) | (lon & 0xFFFF_FFFF)
  }

  static func kilometres(_ a: Moment, _ b: Moment) -> Double {
    guard let lat1 = a.latitude, let lon1 = a.longitude, let lat2 = b.latitude, let lon2 = b.longitude else { return 0 }
    let radians = Double.pi / 180
    let dLat = (lat2 - lat1) * radians
    let dLon = (lon2 - lon1) * radians
    let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * radians) * cos(lat2 * radians) * sin(dLon / 2) * sin(dLon / 2)
    return 6_371 * 2 * atan2(h.squareRoot(), (1 - h).squareRoot())
  }
}

/// Shared in-memory cache of reverse-geocoded city/region names by rounded coordinate (~1 km)
/// so Search Memories, Widgets and Places don't repeat MapKit lookups on scroll or refresh.
actor PlaceNameCache {
  static let shared = PlaceNameCache()

  private struct Key: Hashable, Sendable {
    let lat: Int
    let lon: Int

    init(latitude: Double, longitude: Double) {
      lat = Int((latitude * 100).rounded())
      lon = Int((longitude * 100).rounded())
    }
  }

  private struct Entry: Sendable {
    let city: String?
    let region: String?
  }

  private var entries: [Key: Entry] = [:]
  private var inFlight: [Key: Task<Entry?, Never>] = [:]
  private let limit = 512

  func cityName(latitude: Double, longitude: Double) async -> String? {
    await lookup(latitude: latitude, longitude: longitude)?.city
  }

  func placeName(latitude: Double, longitude: Double) async -> String? {
    let entry = await lookup(latitude: latitude, longitude: longitude)
    return entry?.city ?? entry?.region
  }

  private func lookup(latitude: Double, longitude: Double) async -> Entry? {
    let key = Key(latitude: latitude, longitude: longitude)
    if let cached = entries[key] { return cached }
    if let existing = inFlight[key] { return await existing.value }
    let task = Task<Entry?, Never>(priority: .utility) {
      guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude))
      else { return nil }
      let item = try? await request.mapItems.first
      let city = item?.addressRepresentations?.cityName
      let region = item?.addressRepresentations?.regionName
      guard city != nil || region != nil else { return nil }
      return Entry(city: city, region: region)
    }
    inFlight[key] = task
    let result = await task.value
    inFlight[key] = nil
    if let result {
      if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
      entries[key] = result
    }
    return result
  }
}

/// Similar-photo groups built while prints stream in, oldest first: each print is compared
/// with the few just before it in the same window, and only that window's vectors are
/// held. Same groups as `SimilarityGrouping`, in constant memory.
struct StreamingSimilarity {
  let window: TimeInterval
  let maxNeighbors: Int
  let threshold: Float
  private(set) var ids: [String] = []
  private(set) var scores: [Float?] = []
  private var parent: [Int] = []
  private var recent: [(index: Int, date: Date, vector: [Float])] = []

  init(window: TimeInterval = 120, maxNeighbors: Int = 24, threshold: Float = 0.3) {
    self.window = window
    self.maxNeighbors = maxNeighbors
    self.threshold = threshold
  }

  mutating func add(id: String, date: Date, print: Data, score: Float?) {
    let index = ids.count
    ids.append(id)
    scores.append(score)
    parent.append(index)
    let floatCount = print.count / MemoryLayout<Float>.size
    var vector = [Float](repeating: 0, count: floatCount)
    if floatCount > 0 {
      _ = vector.withUnsafeMutableBytes { buffer in
        print.copyBytes(to: buffer, count: floatCount * MemoryLayout<Float>.size)
      }
    }
    recent.removeAll { date.timeIntervalSince($0.date) > window }
    let squaredThreshold = threshold * threshold
    for other in recent where other.vector.count == vector.count {
      var squared: Float = 0
      vDSP_distancesq(vector, 1, other.vector, 1, &squared, vDSP_Length(vector.count))
      if squared < squaredThreshold { union(index, other.index) }
    }
    recent.append((index, date, vector))
    if recent.count > maxNeighbors { recent.removeFirst(recent.count - maxNeighbors) }
  }

  private mutating func root(_ index: Int) -> Int {
    var index = index
    while parent[index] != index {
      parent[index] = parent[parent[index]]
      index = parent[index]
    }
    return index
  }

  private mutating func union(_ a: Int, _ b: Int) {
    let (first, second) = (root(a), root(b))
    if first != second { parent[max(first, second)] = min(first, second) }
  }

  /// Groups of two or more, as indices into `ids`, oldest first.
  mutating func groups() -> [[Int]] {
    var groups: [Int: [Int]] = [:]
    for index in ids.indices { groups[root(index), default: []].append(index) }
    return groups.values.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }
  }
}
