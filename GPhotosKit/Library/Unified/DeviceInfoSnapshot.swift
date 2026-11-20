import Foundation
import Photos

/// The device library's merge details, kept between launches. Reading the date, size and
/// place of every asset faults every `PHAsset`, which takes seconds at 100,000 items;
/// PhotoKit's change history names the assets changed since the save, so only those are
/// read again. Anything the history can't vouch for falls back to reading everything.
enum DeviceInfoSnapshot {
  private static let magic: UInt32 = 0x4449_5331  // "DIS1"
  /// A sparse check catches a set that drifted without showing in the history (shared
  /// albums, a pruned history); a moved item changes every index after it.
  private static let sampleCount = 256
  /// Past this many changes reading everything is about as fast, and simpler to trust.
  private static let maxChangedItems = 5_000
  private static let maxTies = 2_000

  static var fileURL: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("DeviceLibrary.snapshot")
  }

  /// The infos of `result`, in its order: from the saved snapshot plus the history when
  /// they provably match the fetch, else read from every asset. Saves what it returns.
  static func infos(for result: PHFetchResult<PHAsset>) -> [DeviceItemInfo] {
    let library = PHPhotoLibrary.shared()
    // Taken before reading, so a change made meanwhile is replayed next time.
    let token = library.currentChangeToken
    if let updated = updatedInfos(for: result, library: library) {
      if updated.changed { save(updated.infos, token: token) }
      return updated.infos
    }
    let infos = readAll(result)
    save(infos, token: token)
    return infos
  }

  static func readAll(_ result: PHFetchResult<PHAsset>) -> [DeviceItemInfo] {
    var infos: [DeviceItemInfo] = []
    infos.reserveCapacity(result.count)
    var lastDate = Date.distantFuture
    result.enumerateObjects { asset, _, _ in
      // Undated assets sort with their neighbours, as in the fetch.
      let date = asset.creationDate ?? lastDate
      lastDate = date
      infos.append(info(asset, date: date))
    }
    return infos
  }

  private static func info(_ asset: PHAsset, date: Date) -> DeviceItemInfo {
    let coordinate = asset.location?.coordinate
    return DeviceItemInfo(
      localIdentifier: asset.localIdentifier, date: date, width: asset.pixelWidth, height: asset.pixelHeight,
      isVideo: asset.mediaType == .video, isFavorite: asset.isFavorite, latitude: coordinate?.latitude,
      longitude: coordinate?.longitude, subtypes: asset.mediaSubtypes.rawValue)
  }

  // MARK: Replaying the history

  private static func updatedInfos(
    for result: PHFetchResult<PHAsset>, library: PHPhotoLibrary
  ) -> (infos: [DeviceItemInfo], changed: Bool)? {
    guard let saved = load(), let history = try? library.fetchPersistentChanges(since: saved.token) else { return nil }
    var removed = Set<String>()
    var reread = Set<String>()
    for change in history {
      guard let details = try? change.changeDetails(for: .asset) else { return nil }
      removed.formUnion(details.deletedLocalIdentifiers)
      reread.formUnion(details.updatedLocalIdentifiers)
      reread.formUnion(details.insertedLocalIdentifiers)
      guard removed.count + reread.count <= maxChangedItems else { return nil }
    }
    var infos = saved.infos
    if !removed.isEmpty || !reread.isEmpty {
      infos.removeAll { removed.contains($0.localIdentifier) || reread.contains($0.localIdentifier) }
      let options = PHFetchOptions()
      options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
      var undated = false
      var fresh: [DeviceItemInfo] = []
      PHAsset.fetchAssets(withLocalIdentifiers: Array(reread), options: options).enumerateObjects { asset, _, stop in
        guard let date = asset.creationDate else {
          undated = true
          stop.pointee = true
          return
        }
        fresh.append(info(asset, date: date))
      }
      guard !undated else { return nil }
      // The saved order is the fetch's (undated items carry a neighbour's date), so the
      // changed items are merged into it rather than everything being sorted again.
      infos = Self.merge(infos, fresh.sorted { $0.date > $1.date })
    }
    guard align(&infos, with: result) else { return nil }
    return (infos, !removed.isEmpty || !reread.isEmpty)
  }

  /// Two newest-first lists as one; on equal dates the saved item comes first (ties are
  /// put in PhotoKit's order afterwards).
  static func merge(_ saved: [DeviceItemInfo], _ fresh: [DeviceItemInfo]) -> [DeviceItemInfo] {
    guard !fresh.isEmpty else { return saved }
    var merged: [DeviceItemInfo] = []
    merged.reserveCapacity(saved.count + fresh.count)
    var i = 0
    var j = 0
    while i < saved.count, j < fresh.count {
      if fresh[j].date > saved[i].date {
        merged.append(fresh[j])
        j += 1
      } else {
        merged.append(saved[i])
        i += 1
      }
    }
    merged += saved[i...]
    merged += fresh[j...]
    return merged
  }

  /// Checks `infos` against the fetch: the same count, the same ids at evenly spaced
  /// positions, and each run of equal dates (the only places the date sort can't decide)
  /// holding the same items, which are then put in the fetch's order.
  private static func align(_ infos: inout [DeviceItemInfo], with result: PHFetchResult<PHAsset>) -> Bool {
    let count = infos.count
    guard count == result.count else { return false }
    guard count > 0 else { return true }
    let step = max(1, count / sampleCount)
    for position in Array(stride(from: 0, to: count, by: step)) + [count - 1]
    where result.object(at: position).localIdentifier != infos[position].localIdentifier {
      // A tie can disagree here; it is settled with its run below.
      let isTied =
        (position > 0 && infos[position - 1].date == infos[position].date)
        || (position < count - 1 && infos[position + 1].date == infos[position].date)
      if !isTied { return false }
    }
    var tied = 0
    var start = 0
    while start < count {
      var end = start + 1
      while end < count, infos[end].date == infos[start].date { end += 1 }
      if end - start > 1 {
        tied += end - start
        guard tied <= maxTies else { return false }
        var byID: [String: DeviceItemInfo] = [:]
        for info in infos[start..<end] { byID[info.localIdentifier] = info }
        for position in start..<end {
          guard let info = byID.removeValue(forKey: result.object(at: position).localIdentifier) else { return false }
          infos[position] = info
        }
      }
      start = end
    }
    return true
  }

  // MARK: File

  private struct Saved {
    let token: PHPersistentChangeToken
    let infos: [DeviceItemInfo]
  }

  /// Flat little-endian records: no per-item objects to decode, so 100,000 items load in
  /// a few milliseconds.
  private static func save(_ infos: [DeviceItemInfo], token: PHPersistentChangeToken) {
    guard let tokenData = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    else { return }
    var data = Data()
    data.reserveCapacity(64 + tokenData.count + infos.count * 96)
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func append(_ value: Double) { append(value.bitPattern) }
    append(magic)
    append(UInt32(tokenData.count))
    data.append(tokenData)
    append(UInt32(infos.count))
    for info in infos {
      let id = Data(info.localIdentifier.utf8)
      append(UInt16(id.count))
      data.append(id)
      append(info.date.timeIntervalSinceReferenceDate)
      append(Int32(clamping: info.width))
      append(Int32(clamping: info.height))
      let hasLocation = info.latitude != nil && info.longitude != nil
      append(UInt8((info.isVideo ? 1 : 0) | (info.isFavorite ? 2 : 0) | (hasLocation ? 4 : 0)))
      if hasLocation {
        append(info.latitude ?? 0)
        append(info.longitude ?? 0)
      }
      append(UInt64(info.subtypes))
    }
    try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  private static func load() -> Saved? {
    guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
    return data.withUnsafeBytes { raw -> Saved? in
      var offset = 0
      func read<T: FixedWidthInteger>(_: T.Type) -> T? {
        guard offset + MemoryLayout<T>.size <= raw.count else { return nil }
        defer { offset += MemoryLayout<T>.size }
        return T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self))
      }
      func readDouble() -> Double? { read(UInt64.self).map(Double.init(bitPattern:)) }
      func readBytes(_ count: Int) -> UnsafeRawBufferPointer? {
        guard offset + count <= raw.count else { return nil }
        defer { offset += count }
        return UnsafeRawBufferPointer(rebasing: raw[offset..<offset + count])
      }
      guard read(UInt32.self) == magic, let tokenCount = read(UInt32.self),
        let tokenBytes = readBytes(Int(tokenCount)),
        let token = try? NSKeyedUnarchiver.unarchivedObject(
          ofClass: PHPersistentChangeToken.self, from: Data(tokenBytes)),
        let count = read(UInt32.self)
      else { return nil }
      var infos: [DeviceItemInfo] = []
      infos.reserveCapacity(Int(count))
      for _ in 0..<count {
        guard let idCount = read(UInt16.self), let idBytes = readBytes(Int(idCount)),
          let date = readDouble(), let width = read(Int32.self), let height = read(Int32.self),
          let flags = read(UInt8.self)
        else { return nil }
        var latitude: Double?
        var longitude: Double?
        if flags & 4 != 0 {
          guard let lat = readDouble(), let lon = readDouble() else { return nil }
          latitude = lat
          longitude = lon
        }
        guard let subtypes = read(UInt64.self) else { return nil }
        infos.append(
          DeviceItemInfo(
            localIdentifier: String(decoding: idBytes, as: UTF8.self),
            date: Date(timeIntervalSinceReferenceDate: date), width: Int(width), height: Int(height),
            isVideo: flags & 1 != 0, isFavorite: flags & 2 != 0, latitude: latitude, longitude: longitude,
            subtypes: UInt(subtypes)))
      }
      return Saved(token: token, infos: infos)
    }
  }
}
