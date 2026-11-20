import Accelerate
import Foundation

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
          if lookup[bucket, default: []].count < 128, !lookup[bucket, default: []].contains(index) {
            lookup[bucket, default: []].append(index)
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
          for neighbor in [key] + (0..<10).map({ key ^ (1 << $0) }) {
            for index in lookup[Int64(table) * 1024 + neighbor] ?? [] where !groups[index].faces.isEmpty {
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

  /// Four independent locality-sensitive hashes shortlist candidates in SQLite, keeping
  /// vectors bounded even when the library has hundreds of thousands of faces.
  static func buckets(_ data: Data) -> [Int64] {
    let vector = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    guard !vector.isEmpty, vector.allSatisfy({ $0.isFinite }) else { return [] }
    var state: UInt64 = 0x4d59_5df4_d0f3_3173
    func random() -> UInt64 {
      state = state &* 6_364_136_223_846_793_005 &+ 1
      return state >> 32
    }
    return (0..<4).map { _ in
      var key: Int64 = 0
      for bit in 0..<10 {
        var projection: Float = 0
        for _ in 0..<32 {
          let index = Int(random() % UInt64(vector.count))
          projection += vector[index] * (random() & 1 == 0 ? -1 : 1)
        }
        if projection >= 0 { key |= 1 << bit }
      }
      return key
    }
  }
}

/// On This Day and trips, from dates and places across the merged library.
enum MemoryFinder {
  struct Moment: Sendable, Equatable {
    let date: Date
    let latitude: Double?
    let longitude: Double?
  }

  /// Indices of items taken on today's month and day in earlier years, grouped by year,
  /// most recent year first.
  static func onThisDay(_ moments: [Moment], today: Date, calendar: Calendar = .current) -> [(year: Int, indices: [Int])] {
    let target = calendar.dateComponents([.month, .day, .year], from: today)
    var byYear: [Int: [Int]] = [:]
    for (index, moment) in moments.enumerated() {
      let parts = calendar.dateComponents([.month, .day, .year], from: moment.date)
      guard parts.month == target.month, parts.day == target.day, let year = parts.year, year < (target.year ?? 0)
      else { continue }
      byYear[year, default: []].append(index)
    }
    return byYear.sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
  }

  /// Runs of items far from home on nearby days. Home is the most common place.
  static func trips(
    _ moments: [Moment], minimumItems: Int = 12, awayKilometres: Double = 100, maximumGapDays: Double = 2
  ) -> [[Int]] {
    let located = moments.indices.filter { moments[$0].latitude != nil && moments[$0].longitude != nil }
    guard located.count >= minimumItems else { return [] }
    var cells: [String: Int] = [:]
    for index in located {
      cells[cell(moments[index]), default: 0] += 1
    }
    guard let home = cells.max(by: { $0.value < $1.value })?.key,
      let homeIndex = located.first(where: { cell(moments[$0]) == home })
    else { return [] }
    let homeMoment = moments[homeIndex]
    let away =
      located
      .filter { kilometres(moments[$0], homeMoment) > awayKilometres }
      .sorted { moments[$0].date < moments[$1].date }
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

  private static func cell(_ moment: Moment) -> String {
    "\(Int(((moment.latitude ?? 0) * 2).rounded())):\(Int(((moment.longitude ?? 0) * 2).rounded()))"
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
    let vector = print.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
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
