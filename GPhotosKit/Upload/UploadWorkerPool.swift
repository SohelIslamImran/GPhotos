import Foundation
import Observation
import os

private let uploadLogger = Logger(subsystem: "org.gphotosapp.gphotos", category: "UploadWorkerPool")

#if os(iOS)
  import UIKit
#endif

#if canImport(Photos)
  import Photos
#endif

// MARK: - Power & Background Assertion Manager

/// Manages a reference-counted activity assertion for active transfers.
@MainActor
public final class PowerAssertionManager {
  public static let shared = PowerAssertionManager()

  private var assertionCount = 0
  private var expirationHandlers: [@MainActor () -> Void] = []

  #if os(macOS)
    private var activityToken: NSObjectProtocol?
  #elseif os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
  #endif

  private init() {}

  /// `onExpiration` runs if the system reclaims the assertion; the holder no longer
  /// owns it then and must not release it.
  public func acquireAssertion(
    reason: String = "GPhotosSync Media Transfer",
    onExpiration: (@MainActor () -> Void)? = nil
  ) {
    if let onExpiration {
      expirationHandlers.append(onExpiration)
    }
    if assertionCount > 0 {
      assertionCount += 1
      return
    }

    #if os(macOS)
      let options: ProcessInfo.ActivityOptions = [.userInitiated]
      activityToken = ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
    #elseif os(iOS)
      // Background task assertion gives ~30s execution time when transitioning to background
      backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: reason) {
        // The task must be ended before this handler returns or the app is killed,
        // so it cannot hop through a Task. UIKit calls it on the main thread.
        MainActor.assumeIsolated {
          PowerAssertionManager.shared.expire()
        }
      }
      // Auto-lock suspends the app mid-upload, so the screen stays on while it runs.
      UIApplication.shared.isIdleTimerDisabled = true
    #endif

    assertionCount = 1
  }

  #if os(iOS)
    private func expire() {
      let handlers = expirationHandlers
      expirationHandlers.removeAll()
      assertionCount = 0
      if backgroundTaskID != .invalid {
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
      }
      UIApplication.shared.isIdleTimerDisabled = false
      for handler in handlers {
        handler()
      }
    }
  #endif

  public func releaseAssertion() {
    guard assertionCount > 0 else { return }
    assertionCount -= 1
    guard assertionCount == 0 else { return }
    expirationHandlers.removeAll()

    #if os(macOS)
      if let token = activityToken {
        ProcessInfo.processInfo.endActivity(token)
        activityToken = nil
      }
    #elseif os(iOS)
      if backgroundTaskID != .invalid {
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
      }
      UIApplication.shared.isIdleTimerDisabled = false
    #endif

  }

}

// MARK: - Worker State

public struct WorkerState: Identifiable, Sendable, Equatable {
  public let id: Int
  public var itemID: String = ""
  public var status: String  // "idle", "hashing", "checking", "uploading", "finalizing", "completed", "skipped", "error"
  public var filename: String
  public var message: String
  public var bytesUploaded: Int64
  public var bytesTotal: Int64
  public var speedBytesPerSec: Double = 0
  public var formattedSpeed: String = ""
  public var estimatedSecondsRemaining: TimeInterval? = nil
  public var formattedETA: String = ""
  public var lastUpdateTime: Date? = nil
  public var lastBytesCount: Int64 = 0

  public var progress: Double {
    bytesTotal > 0 ? min(status == "completed" ? 1 : 0.99, Double(bytesUploaded) / Double(bytesTotal)) : 0
  }

  /// Stable per file: a worker slot moving to the next file reads as a new row.
  public var rowKey: String { "\(id)-\(itemID.isEmpty ? filename : itemID)" }

  public init(
    id: Int,
    itemID: String = "",
    status: String = "idle",
    filename: String = "",
    message: String = "Ready",
    bytesUploaded: Int64 = 0,
    bytesTotal: Int64 = 0
  ) {
    self.id = id
    self.itemID = itemID
    self.status = status
    self.filename = filename
    self.message = message
    self.bytesUploaded = bytesUploaded
    self.bytesTotal = bytesTotal
  }

  public mutating func updateTransferMetrics(currentBytes: Int64, totalBytes: Int64? = nil) {
    if let total = totalBytes {
      self.bytesTotal = total
    }
    self.bytesUploaded = max(self.bytesUploaded, currentBytes)

    let now = Date()
    guard let lastTime = lastUpdateTime, lastBytesCount > 0 else {
      lastUpdateTime = now
      lastBytesCount = currentBytes
      return
    }

    let elapsed = now.timeIntervalSince(lastTime)
    guard elapsed >= 1 else { return }

    let bytesDelta = currentBytes - lastBytesCount
    if bytesDelta >= 0 {
      let instantSpeed = Double(bytesDelta) / elapsed
      let smoothedSpeed = speedBytesPerSec > 0 ? (0.75 * speedBytesPerSec + 0.25 * instantSpeed) : instantSpeed
      self.speedBytesPerSec = smoothedSpeed

      if smoothedSpeed > 1024 {
        self.formattedSpeed = "\(ByteFormat.string(Int64(smoothedSpeed)))/s"
        let remainingBytes = max(0, bytesTotal - currentBytes)
        let eta = Double(remainingBytes) / smoothedSpeed
        self.estimatedSecondsRemaining = eta
        self.formattedETA = WorkerState.formatETA(eta)
      } else {
        self.formattedSpeed = ""
        self.estimatedSecondsRemaining = nil
        self.formattedETA = ""
      }
    }

    self.lastUpdateTime = now
    self.lastBytesCount = currentBytes
  }

  public mutating func resetMetrics() {
    self.speedBytesPerSec = 0
    self.formattedSpeed = ""
    self.estimatedSecondsRemaining = nil
    self.formattedETA = ""
    self.lastUpdateTime = nil
    self.lastBytesCount = 0
  }

  public static func formatETA(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite && !seconds.isNaN && seconds > 0 else { return "" }
    let s = Int(seconds)
    if s < 60 {
      return "\(s)s left"
    } else if s < 3600 {
      let mins = s / 60
      let remSecs = s % 60
      return remSecs > 0 ? "\(mins)m \(remSecs)s left" : "\(mins)m left"
    } else {
      let hrs = s / 3600
      let mins = (s % 3600) / 60
      return mins > 0 ? "\(hrs)h \(mins)m left" : "\(hrs)h left"
    }
  }
}

public struct UploadQueueItem: Identifiable, Sendable {
  public let id: String
  public let fileURL: URL
  public let filename: String
  public let livePhotoExport: LivePhotoExport?
  public let fileSize: Int64
  public let creationDate: Date?
  public let assetLocalIdentifier: String?
  /// Which of the asset's resources this item exports. Only `.primary` pairs a Live
  /// Photo's motion.
  public let resourceRole: AssetResourceRole
  public let isTemporaryFile: Bool
  /// Google Photos albums this item belongs to. One upload can land in several albums,
  /// which is what mirroring a photo library requires: a photo in "Favorites" and
  /// "2026 Vacation" is uploaded once and added to both.
  public let albumNames: [String]
  public let precomputedSHA1: String?
  public let precomputedSourceModifiedAt: Date?
  public let pairLivePhotos: Bool
  public let removeSourceOnSuccess: Bool
  private(set) var mirrorSource: TransferRecord?

  public init(
    id: String = UUID().uuidString,
    fileURL: URL,
    filename: String? = nil,
    livePhotoExport: LivePhotoExport? = nil,
    fileSize: Int64? = nil,
    creationDate: Date? = nil,
    assetLocalIdentifier: String? = nil,
    resourceRole: AssetResourceRole = .primary,
    isTemporaryFile: Bool = false,
    albumNames: [String] = [],
    precomputedSHA1: String? = nil,
    precomputedSourceModifiedAt: Date? = nil,
    pairLivePhotos: Bool = true,
    removeSourceOnSuccess: Bool = false
  ) {
    self.id = id
    self.fileURL = fileURL
    self.filename = filename ?? fileURL.lastPathComponent
    self.livePhotoExport = livePhotoExport
    self.creationDate = creationDate
    self.assetLocalIdentifier = assetLocalIdentifier
    self.resourceRole = resourceRole
    self.isTemporaryFile = isTemporaryFile
    self.albumNames = albumNames
    self.precomputedSHA1 = precomputedSHA1
    self.precomputedSourceModifiedAt = precomputedSourceModifiedAt
    self.pairLivePhotos = pairLivePhotos
    self.removeSourceOnSuccess = removeSourceOnSuccess

    if let livePhotoExport {
      self.fileSize = livePhotoExport.photoSize + livePhotoExport.videoSize
    } else if let fileSize {
      self.fileSize = fileSize
    } else {
      let attrs = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) ?? [:]
      self.fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }
  }

  func withID(_ newID: String, mirrorSource: TransferRecord) -> UploadQueueItem {
    var item = UploadQueueItem(
      id: newID,
      fileURL: fileURL,
      filename: filename,
      livePhotoExport: livePhotoExport,
      fileSize: fileSize,
      creationDate: creationDate,
      assetLocalIdentifier: assetLocalIdentifier,
      resourceRole: resourceRole,
      isTemporaryFile: isTemporaryFile,
      albumNames: albumNames,
      precomputedSHA1: precomputedSHA1,
      precomputedSourceModifiedAt: precomputedSourceModifiedAt,
      pairLivePhotos: pairLivePhotos,
      removeSourceOnSuccess: false
    )
    item.mirrorSource = mirrorSource
    return item
  }

  func cachedSHA1(for url: URL) -> Data? {
    guard url == fileURL, let precomputedSHA1, let decoded = Data(base64Encoded: precomputedSHA1), decoded.count == 20,
      let expected = precomputedSourceModifiedAt,
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let modifiedAt = attributes[.modificationDate] as? Date,
      abs(modifiedAt.timeIntervalSince(expected)) < 0.01
    else { return nil }
    return decoded
  }
}

public struct ProcessResult: Sendable {
  public let workerID: Int
  public let filename: String
  public let mediaKey: String?
  public let fileSize: Int64
  public let albumNames: [String]

  public init(workerID: Int, filename: String, mediaKey: String?, fileSize: Int64, albumNames: [String] = []) {
    self.workerID = workerID
    self.filename = filename
    self.mediaKey = mediaKey
    self.fileSize = fileSize
    self.albumNames = albumNames
  }
}

/// One-shot latch. `resume()` may arrive before `wait()` stores its continuation, so
/// the signal is latched rather than dropped — otherwise the waiter parks forever.
final class OneShotSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var isResumed = false

  func wait() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      if isResumed {
        lock.unlock()
        continuation.resume()
      } else {
        self.continuation = continuation
        lock.unlock()
      }
    }
  }

  func resume() {
    lock.lock()
    guard !isResumed else {
      lock.unlock()
      return
    }
    isResumed = true
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume()
  }
}

/// Lets a callback that runs off the main actor reach a pool without keeping it alive.
private final class PoolReference: @unchecked Sendable {
  @MainActor weak var pool: UploadWorkerPool?
  @MainActor init(_ pool: UploadWorkerPool) { self.pool = pool }
}

// MARK: - Upload Worker Pool

@MainActor
@Observable
public final class UploadWorkerPool {
  public private(set) var isRunning = false
  public private(set) var isBatchFinalizing = false
  public private(set) var isPaused = false
  public private(set) var isStopping = false
  public private(set) var workers: [WorkerState] = []
  public private(set) var currentFilename: String?
  public private(set) var currentProgress: Double = 0
  public private(set) var currentTransferredBytes: Int64 = 0
  public private(set) var currentTotalBytes: Int64 = 0
  public private(set) var completedItemsBytes: Int64 = 0
  public private(set) var statusMessage = "Ready"

  public private(set) var overallSpeedBytesPerSec: Double = 0
  public private(set) var overallFormattedSpeed: String = ""
  public private(set) var overallFormattedETA: String = ""

  public var maxConcurrency: Int = 3
  public var useFilenameDate = true
  public var pairLivePhotos = true
  /// Held while a background processing or continued-processing task drives the batch:
  /// such a task outlives the batch's own background time and winds the batch down from its
  /// own expiration handler. Counted because both kinds can overlap.
  private var backgroundExpirationHolds = 0
  /// Set during short background windows: downloading a large original that is only in
  /// iCloud could take the whole window, so such items wait for a pass that may download
  /// them. Smaller ones still download, so an optimized library keeps backing up.
  public var iCloudDownloadLimit: Int64?
  /// Google asked this account to slow down; uploads resume when the wait ends.
  public private(set) var isRateLimited = false
  public var claimPhotoUpload: (@Sendable (String) async -> Bool)?
  public var releasePhotoUpload: (@Sendable (String) -> Void)?
  public var onItemCompleted: (@Sendable () async -> Void)?
  public var onItemFinished: (@Sendable (String, TransferStatus) async -> Void)?
  public var onBatchCompleted: (@Sendable () async -> Void)?
  var canStartBatch: ((String?) -> Bool)?
  public var onBatchStarted: (@MainActor @Sendable () -> Void)?
  public var onProgressUpdated: (@MainActor @Sendable () -> Void)?
  public var onBatchCancelled: (@MainActor @Sendable () -> Void)?
  public private(set) var lastBatchCompletedCount: Int = 0
  public private(set) var lastBatchFailedCount: Int = 0
  private(set) var lastItemRanOutOfSpace = false
  /// The network went away during the batch, which stopped so its items stay pending.
  public private(set) var lastBatchLostNetwork = false
  @ObservationIgnored private var networkDeferrals: [String: Int] = [:]
  private static let maxNetworkDeferrals = 3
  public private(set) var lastBatchAuthErrorEmail: String?
  /// Set when Google said the account is out of storage; the batch stopped there and the
  /// items it had not reached stay pending.
  public private(set) var lastBatchStorageFullEmail: String?
  public private(set) var lastBatchTotalCount: Int = 0
  public var isBatchCancelled: Bool { isCancelled }
  @ObservationIgnored private var batchProgress = BatchUploadProgress()
  @ObservationIgnored private var metricsTask: Task<Void, Never>?
  private var currentAccountEmail: String?
  private var pendingQueue: [UploadQueueItem] = []
  private var inFlightSHA1 = Set<String>()
  private(set) var sha1Waiters: [String: [OneShotSignal]] = [:]

  private let client: GooglePhotosMobileClient
  private let manifestStore: TransferManifestStore
  private var activeTask: Task<Void, Never>?
  private var batchWaiters: [UUID: OneShotSignal] = [:]
  private var isCancelled = false
  private var isCancelling = false
  private var generation = 0
  private var discardedItems: [UploadQueueItem] = []
  private var holdsPowerAssertion = false
  private var pauseSignal: OneShotSignal?
  private var albumTask: Task<[String], Never>?
  private var skipsAlbumUpdates = false
  private var canDispatchUploads: Bool {
    !isCancelled && !isDrainCancelled && !lastBatchLostNetwork
      && lastBatchStorageFullEmail == nil && lastBatchAuthErrorEmail == nil
  }
  private static var abandonedExportCleanup: Task<Void, Never>?

  public init(client: GooglePhotosMobileClient, manifestStore: TransferManifestStore) {
    self.client = client
    self.manifestStore = manifestStore
    // Every pool waits on the same launch cleanup, so it can never remove a live export.
    if Self.abandonedExportCleanup == nil {
      Self.abandonedExportCleanup = Task.detached(priority: .utility) {
        try? FileManager.default.removeItem(at: LivePhotoManager.exportRoot)
      }
    }
    self.updateWorkerCount(maxConcurrency)
    PreparationGuard.shared.observeCleanExits()
    // Weak, so a pool dropped with its account is not kept alive by its client.
    let reference = PoolReference(self)
    Task { [client] in
      await client.setRateLimitObserver { limited, sequence in
        Task { @MainActor in reference.pool?.rateLimitChanged(limited, sequence: sequence) }
      }
    }
  }

  private var lastRateLimitReport = 0

  private func rateLimitChanged(_ limited: Bool, sequence: Int) {
    guard sequence > lastRateLimitReport else { return }
    lastRateLimitReport = sequence
    guard isRateLimited != limited else { return }
    isRateLimited = limited
    onProgressUpdated?()
  }

  private func acquirePowerAssertion() {
    guard !holdsPowerAssertion else { return }
    PowerAssertionManager.shared.acquireAssertion { [weak self] in
      self?.powerAssertionExpired()
    }
    holdsPowerAssertion = true
  }

  private func releasePowerAssertion() {
    guard holdsPowerAssertion else { return }
    PowerAssertionManager.shared.releaseAssertion()
    holdsPowerAssertion = false
  }

  /// The system took the background time back, so a transfer left running would be
  /// frozen mid-upload at suspension; stopping returns its items to the queue.
  private func powerAssertionExpired() {
    holdsPowerAssertion = false
    guard backgroundExpirationHolds == 0 else { return }
    // Suspension follows, and the items being cancelled may not unwind before it.
    PreparationGuard.shared.forgetInFlight()
    cancel()
  }

  public func holdThroughBackgroundExpiration() {
    backgroundExpirationHolds += 1
  }

  public func releaseBackgroundExpirationHold() {
    backgroundExpirationHolds = max(0, backgroundExpirationHolds - 1)
  }

  private func wakePausedDispatch() {
    pauseSignal?.resume()
    pauseSignal = nil
  }

  @MainActor
  public func recalculateOverallProgress() {
    let now = ProcessInfo.processInfo.systemUptime
    batchProgress.sample(at: now)
    for index in workers.indices {
      if let last = workers[index].lastUpdateTime, Date().timeIntervalSince(last) >= 3,
        workers[index].speedBytesPerSec > 0
      {
        workers[index].resetMetrics()
      }
    }
    let transferred = batchProgress.transferredBytes
    let progress = isRunning || isBatchFinalizing ? min(0.99, batchProgress.fraction) : batchProgress.fraction
    if currentTotalBytes != batchProgress.totalBytes { currentTotalBytes = batchProgress.totalBytes }
    let activeSpeeds = !isRunning || isPaused || isRateLimited ? 0 : (batchProgress.speed(at: now) ?? 0)
    // Formatting is only worth doing when the value a reader can see actually moves.
    let speedText: String
    let etaText: String
    if activeSpeeds > 1024 {
      speedText = "\(ByteFormat.string(Int64(activeSpeeds)))/s"
      etaText = WorkerState.formatETA(Double(max(0, currentTotalBytes - transferred)) / activeSpeeds)
    } else {
      speedText = ""
      etaText = ""
    }

    guard
      transferred != currentTransferredBytes
        || progress != currentProgress
        || activeSpeeds != overallSpeedBytesPerSec
        || speedText != overallFormattedSpeed
        || etaText != overallFormattedETA
    else { return }

    currentTransferredBytes = transferred
    currentProgress = progress
    overallSpeedBytesPerSec = activeSpeeds
    overallFormattedSpeed = speedText
    overallFormattedETA = etaText
    onProgressUpdated?()
  }

  /// How many media keys go in a single `createAlbum` request. The remainder is
  /// attached with the chunked add call, which handles far larger batches.
  private static let albumCreateBatchLimit = 50

  public func setConcurrency(_ count: Int) {
    let clamped = max(1, min(8, count))
    maxConcurrency = clamped
    if !isRunning {
      updateWorkerCount(clamped)
    }
  }

  private func updateWorkerCount(_ count: Int) {
    if workers.count != count {
      workers = (0..<count).map { WorkerState(id: $0) }
    }
  }

  /// Result of asking the pool to take a set of items.
  public enum StartOutcome: Equatable {
    /// A new batch is running.
    case started
    /// Every item was already queued or in flight. The caller must keep its upload
    /// claims: releasing them here would un-claim a transfer that is still running.
    case alreadyTracked
    /// The pool refused the work, so the caller should release its upload claims.
    case rejected
  }

  @discardableResult
  public func start(
    items: [UploadQueueItem],
    quality: Int64 = 3,
    accountEmail: String? = nil
  ) -> StartOutcome {
    guard !Task.isCancelled, !items.isEmpty, !isStopping, !isBatchFinalizing, canStartBatch?(accountEmail) != false else {
      return .rejected
    }
    if isRunning {
      guard !isCancelling, accountEmail == currentAccountEmail else { return .rejected }
      let previousCount = pendingQueue.count
      enqueue(items: items)
      if pendingQueue.count > previousCount {
        onBatchStarted?()
        return .started
      }
      return .alreadyTracked
    }

    var seenIDs = Set<String>()
    let uniqueItems = items.filter { seenIDs.insert($0.id).inserted }
    guard !uniqueItems.isEmpty else { return .rejected }

    self.currentAccountEmail = accountEmail
    self.lastBatchTotalCount = uniqueItems.count
    self.lastBatchCompletedCount = 0
    self.lastBatchFailedCount = 0
    self.lastItemRanOutOfSpace = false
    self.lastBatchAuthErrorEmail = nil
    self.lastBatchStorageFullEmail = nil
    self.lastBatchLostNetwork = false
    generation += 1
    let batchGeneration = generation
    isRunning = true
    isPaused = false
    isStopping = false
    isCancelled = false
    skipsAlbumUpdates = false
    statusMessage = "Starting upload..."

    // An item that was in flight when the process last died goes last, so everything else
    // backs up first.
    let suspects = uniqueItems.filter { PreparationGuard.shared.isSuspect($0.id) }
    pendingQueue = suspects.isEmpty ? uniqueItems : uniqueItems.filter { !PreparationGuard.shared.isSuspect($0.id) } + suspects
    isDrainCancelled = false
    refreshTrackedItemIDs()
    pendingWorkerProgress.removeAll(keepingCapacity: true)
    batchProgress = BatchUploadProgress()
    for item in uniqueItems { batchProgress.include(id: item.id, size: item.fileSize) }
    batchProgress.sample(at: ProcessInfo.processInfo.systemUptime)
    metricsTask?.cancel()
    metricsTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let self, self.isRunning else { return }
        self.flushWorkerProgress()
      }
    }
    completedItemsBytes = 0
    currentTotalBytes = uniqueItems.reduce(0) { $0 + $1.fileSize }
    currentTransferredBytes = 0
    currentProgress = 0
    overallFormattedETA = ""
    onBatchStarted?()

    activeTask = Task {
      await Self.abandonedExportCleanup?.value
      await self.executeUploadBatch(quality: quality, generation: batchGeneration)
    }
    return .started
  }

  /// Waits for the active batch. Bounded by `timeout` so a background-task
  /// expiration handler can always complete inside the system's window.
  public func waitForCurrentBatch(timeout: Duration? = nil) async {
    guard isRunning || isBatchFinalizing, !Task.isCancelled else { return }
    let id = UUID()
    let signal = OneShotSignal()
    batchWaiters[id] = signal
    let timer = timeout.map { duration in
      Task {
        try? await Task.sleep(for: duration)
        signal.resume()
      }
    }
    await withTaskCancellationHandler {
      await signal.wait()
    } onCancel: {
      signal.resume()
    }
    timer?.cancel()
    batchWaiters[id] = nil
  }

  /// Bounds a system callback even if the work is still unwinding cancellation.
  public static func wait(timeout: Duration, for operation: @escaping @MainActor @Sendable () async -> Void) async {
    let signal = OneShotSignal()
    Task {
      await operation()
      signal.resume()
    }
    let timer = Task {
      try? await Task.sleep(for: timeout)
      signal.resume()
    }
    await withTaskCancellationHandler {
      await signal.wait()
    } onCancel: {
      signal.resume()
    }
    timer.cancel()
  }

  /// Serialises identical content so the same file is never uploaded twice at once.
  /// Waiters park on a continuation instead of polling, and a cancelled waiter wakes
  /// immediately and removes only itself.
  func acquireSHA1(_ sha1: String) async -> Bool {
    guard !Task.isCancelled else { return false }
    while inFlightSHA1.contains(sha1) {
      guard !Task.isCancelled else { return false }
      let waiter = OneShotSignal()
      sha1Waiters[sha1, default: []].append(waiter)
      await withTaskCancellationHandler {
        await waiter.wait()
      } onCancel: {
        waiter.resume()
      }
      if Task.isCancelled {
        sha1Waiters[sha1]?.removeAll { $0 === waiter }
        if sha1Waiters[sha1]?.isEmpty == true {
          sha1Waiters.removeValue(forKey: sha1)
        }
        return false
      }
    }
    inFlightSHA1.insert(sha1)
    return true
  }

  func releaseSHA1(_ sha1: String) {
    inFlightSHA1.remove(sha1)
    let waiting = sha1Waiters.removeValue(forKey: sha1) ?? []
    for waiter in waiting { waiter.resume() }
  }

  private func waitForSHA1(_ sha1: String, workerID: Int) async -> Bool {
    if inFlightSHA1.contains(sha1) {
      workers[workerID].status = "waiting"
      workers[workerID].message = "Waiting for an identical item"
    }
    guard await acquireSHA1(sha1) else {
      workers[workerID].status = "idle"
      return false
    }
    workers[workerID].status = "checking"
    workers[workerID].message = "Checking Google Photos…"
    return true
  }

  public func hasItem(id: String) -> Bool {
    trackedItemIDs.contains(id)
  }

  /// Every id the pool is currently responsible for: queued, in flight, or cancelled
  /// but not yet released.
  private var trackedItemIDs: Set<String> = []
  private var isDrainCancelled = false

  private func refreshTrackedItemIDs() {
    var ids = Set(pendingQueue.map(\.id))
    ids.formUnion(workers.compactMap { $0.itemID.isEmpty ? nil : $0.itemID })
    ids.formUnion(discardedItems.map(\.id))
    trackedItemIDs = ids
  }

  /// Only valid mid-batch: `start` replaces the queue, so items added while idle
  /// would be dropped along with their upload claims.
  func enqueue(items: [UploadQueueItem]) {
    guard isRunning, !items.isEmpty else { return }
    var newItems: [UploadQueueItem] = []
    for item in items where trackedItemIDs.insert(item.id).inserted {
      newItems.append(item)
    }
    guard !newItems.isEmpty else { return }
    self.pendingQueue.append(contentsOf: newItems)
    self.lastBatchTotalCount += newItems.count
    for item in newItems { batchProgress.include(id: item.id, size: item.fileSize) }
    recalculateOverallProgress()
  }

  public func pause() {
    guard isRunning, !isPaused else { return }
    isPaused = true
    statusMessage = "Paused"
    onProgressUpdated?()
  }

  public func resume() {
    guard isRunning, isPaused else { return }
    isPaused = false
    statusMessage = "Resuming..."
    wakePausedDispatch()
    onProgressUpdated?()
  }

  public func cancel() {
    if isBatchFinalizing { albumTask?.cancel() }
    guard isRunning, !isStopping else { return }
    isStopping = true
    isCancelled = true
    isCancelling = true
    discardedItems.append(contentsOf: pendingQueue)
    pendingQueue.removeAll()
    isDrainCancelled = true
    refreshTrackedItemIDs()
    activeTask?.cancel()
    isPaused = false
    wakePausedDispatch()
    statusMessage = "Stopping upload..."
    onBatchCancelled?()
  }

  /// Drops the current batch's album step, because the account it belongs to is going
  /// away. Call right after `cancel()`.
  public func abortAlbumUpdates() {
    skipsAlbumUpdates = true
    albumTask?.cancel()
  }

  private func executeUploadBatch(quality: Int64, generation: Int) async {
    guard generation == self.generation else { return }
    let workerCount = min(maxConcurrency, max(1, pendingQueue.count))
    updateWorkerCount(workerCount)

    var completedMediaKeys: [String] = []
    var keysByAlbum: [String: [String]] = [:]
    var albumKeySeen: [String: Set<String>] = [:]
    var availableWorkerIDs: [Int] = Array(0..<workerCount)
    var inFlight = 0
    var nextDispatchIndex = 0
    var reservedExports: [Int: Int64] = [:]
    // A suspect runs alone, so a crash it causes isn't also blamed on the items beside it.
    var soloWorkerID: Int?

    // Concurrently process items with worker slot pool (guaranteeing no thread collision)
    await withTaskGroup(of: ProcessResult.self) { group in
      @MainActor func record(_ result: ProcessResult) {
        inFlight -= 1
        reservedExports[result.workerID] = nil
        if result.workerID == soloWorkerID { soloWorkerID = nil }
        availableWorkerIDs.append(result.workerID)
        if let key = result.mediaKey {
          lastBatchCompletedCount += 1
          completedMediaKeys.append(key)
          batchProgress.complete(id: workers[result.workerID].itemID)
          completedItemsBytes = batchProgress.backedUpBytes
          for album in result.albumNames where !album.isEmpty {
            // Byte-identical files dedup to one media key; a bucket must not repeat it.
            if albumKeySeen[album, default: []].insert(key).inserted {
              keysByAlbum[album, default: []].append(key)
            }
          }
        }
        self.recalculateOverallProgress()
      }

      // A full account stops dispatch but still collects the uploads already in flight.
      dispatch: while (nextDispatchIndex < pendingQueue.count && canDispatchUploads || inFlight > 0)
        && !isCancelled && !isDrainCancelled
      {
        while isPaused && !isCancelled && !Task.isCancelled
          && (inFlight > 0 || (nextDispatchIndex < pendingQueue.count && canDispatchUploads))
        {
          // Pause only stops dispatch. Items already in flight keep uploading, so the
          // assertion holds until they finish or a suspension would fail them midway.
          if inFlight > 0, let result = await group.next() {
            record(result)
            continue
          }
          releasePowerAssertion()
          let signal = OneShotSignal()
          pauseSignal = signal
          await withTaskCancellationHandler {
            await signal.wait()
          } onCancel: {
            signal.resume()
          }
        }
        if isCancelled { break }

        while inFlight < workerCount && nextDispatchIndex < pendingQueue.count && !availableWorkerIDs.isEmpty
          && canDispatchUploads && soloWorkerID == nil
        {
          let item = pendingQueue[nextDispatchIndex]
          let isSuspect = PreparationGuard.shared.isSuspect(item.id)
          if isSuspect && inFlight > 0 { break }
          let exportBytes = item.assetLocalIdentifier != nil && item.livePhotoExport == nil ? max(0, item.fileSize) : 0
          if exportBytes > 0, inFlight > 0 {
            // Wait for a worker to free its export before dispatching another one.
            // Independent free-space checks can all pass before any export is written.
            let available = await Self.availableExportCapacity()
            guard !Task.isCancelled, canDispatchUploads, generation == self.generation else { break }
            if isPaused { continue dispatch }
            do {
              try Self.requireFreeSpace(for: exportBytes, reserving: reservedExports.values.reduce(0, +), available: available)
            } catch {
              break
            }
          }
          nextDispatchIndex += 1
          let workerID = availableWorkerIDs.removeFirst()
          reservedExports[workerID] = exportBytes
          inFlight += 1
          if isSuspect { soloWorkerID = workerID }

          group.addTask {
            await self.processItem(item: item, workerID: workerID, quality: quality)
              ?? ProcessResult(
                workerID: workerID,
                filename: item.filename,
                mediaKey: nil,
                fileSize: item.fileSize,
                albumNames: item.albumNames
              )
          }
        }

        if let result = await group.next() {
          record(result)
        }
      }
      // Intake closes before the first suspension after the last item drains: anything
      // `start()`-ed from here on would be accepted and then dropped with the queue.
      isBatchFinalizing = true
      if !lastBatchLostNetwork { networkDeferrals = [:] }
      if nextDispatchIndex < pendingQueue.count {
        discardedItems.append(contentsOf: pendingQueue[nextDispatchIndex...])
      }
    }

    if !keysByAlbum.isEmpty && !skipsAlbumUpdates {
      let accountEmail = currentAccountEmail ?? ""
      // Items already sent belong in their albums even after a cancel, so this runs
      // outside the batch task: its cancellation would fail every album request. Only a
      // Stop during this step or an account change cancels it.
      let task = Task { @MainActor in
        await self.addToAlbums(keysByAlbum, accountEmail: accountEmail, showsProgress: true)
      }
      albumTask = task
      let failedAlbums = await task.value
      albumTask = nil
      if !failedAlbums.isEmpty {
        statusMessage = "Uploaded, but \(failedAlbums.joined(separator: ", ")) could not be created."
      } else {
        statusMessage = finishedStatusMessage(completedCount: completedMediaKeys.count)
      }
    } else {
      statusMessage = finishedStatusMessage(completedCount: completedMediaKeys.count)
    }

    guard generation == self.generation else { return }
    let discarded = discardedItems
    discardedItems = []
    // The dispatch cursor leaves every dispatched item in `pendingQueue`, so it has to
    // be cleared here or `hasItem` reports the whole batch as still in flight and
    // later ingests skip them.
    pendingQueue.removeAll(keepingCapacity: true)
    await manifestStore.releaseUploadClaims(ids: discarded.map(\.id))
    isCancelling = false
    releasePowerAssertion()
    pauseSignal = nil
    isRunning = false
    isPaused = false
    isStopping = false
    currentFilename = nil
    for i in 0..<workers.count {
      workers[i].status = "idle"
      workers[i].message = "Ready"
      workers[i].itemID = ""
      workers[i].resetMetrics()
    }
    refreshTrackedItemIDs()
    await onBatchCompleted?()
    isBatchFinalizing = false
    metricsTask?.cancel()
    if isCancelled || lastBatchLostNetwork {
      batchProgress = BatchUploadProgress()
      completedItemsBytes = 0
    }
    recalculateOverallProgress()
    activeTask = nil
    for waiter in batchWaiters.values { waiter.resume() }
    batchWaiters.removeAll()
  }

  private func finishedStatusMessage(completedCount: Int) -> String {
    if isCancelled { return "Upload cancelled." }
    if lastBatchStorageFullEmail != nil { return GPhotosError.storageFull.localizedDescription }
    if lastBatchAuthErrorEmail != nil { return "Sign in again to continue backing up." }
    if lastBatchLostNetwork { return "Waiting for the network. \(completedCount) items uploaded." }
    return "Upload completed. \(completedCount) items."
  }

  public nonisolated static func isAuthError(_ error: Error) -> Bool {
    if let gError = error as? GPhotosError {
      switch gError {
      case .authFailed, .notAuthenticated, .invalidCredential, .missingCredential:
        return true
      case .httpError(let status, _):
        return status == 401
      default:
        return false
      }
    }
    return false
  }

  /// Adds each album's media keys, in name order. Returns the albums that couldn't be
  /// updated. Only while no batch runs, or from the batch's own album step: two at once
  /// could each create the same album.
  public func addToAlbums(
    _ keysByAlbum: [String: [String]], accountEmail: String, showsProgress: Bool = false
  ) async -> [String] {
    var failed: [String] = []
    for (album, keys) in keysByAlbum.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
      guard !Task.isCancelled else {
        failed.append(album)
        continue
      }
      if showsProgress { statusMessage = "Adding to \(album)…" }
      do {
        try await addToAlbum(named: album, mediaKeys: keys, accountEmail: accountEmail)
      } catch {
        failed.append(album)
      }
    }
    return failed
  }

  /// Reuses the album this name already maps to, rolling over to "<Name> (2)", "(3)"...
  /// when the tracked count would exceed Google Photos' 20,000-item cap. A stored key
  /// the server rejects (the album was deleted) is forgotten and recreated.
  private func addToAlbum(named album: String, mediaKeys keys: [String], accountEmail: String) async throws {
    guard !keys.isEmpty else { return }
    let store = AlbumKeyStore.shared
    let slices = AlbumRollover.planAdditions(
      baseName: album,
      itemCount: keys.count,
      currentCountForName: { store.count(forAlbumNamed: $0, accountEmail: accountEmail) }
    )
    for slice in slices {
      let sliceKeys = Array(keys[slice.range])
      try await addMediaSliceToAlbum(named: slice.albumName, mediaKeys: sliceKeys, accountEmail: accountEmail)
      store.incrementCount(by: sliceKeys.count, forAlbumNamed: slice.albumName, accountEmail: accountEmail)
    }
  }

  private func addMediaSliceToAlbum(named album: String, mediaKeys keys: [String], accountEmail: String) async throws {
    guard !keys.isEmpty else { return }
    let store = AlbumKeyStore.shared
    if let existingKey = store.key(forAlbumNamed: album, accountEmail: accountEmail) {
      do {
        try await client.addMediaToAlbum(albumMediaKey: existingKey, mediaKeys: keys)
        return
      } catch GPhotosError.httpError(let status, _) where (400..<500).contains(status) && status != 401 && status != 429 {
        store.forget(albumNamed: album, accountEmail: accountEmail)
      }
    }
    // Google caps a create request, so a large album is created with the first slice
    // and filled through the chunked add path.
    let firstSlice = Array(keys.prefix(Self.albumCreateBatchLimit))
    let remainder = Array(keys.dropFirst(Self.albumCreateBatchLimit))
    let albumKey = try await client.createAlbum(albumName: album, mediaKeys: firstSlice)
    store.remember(key: albumKey, forAlbumNamed: album, accountEmail: accountEmail)
    if !remainder.isEmpty {
      try await client.addMediaToAlbum(albumMediaKey: albumKey, mediaKeys: remainder)
    }
  }

  /// Not the item's fault, and no other item can get further: they all wait for the network.
  /// Unless the device looks online and this item keeps failing (a video that always times
  /// out, say): then it fails like any other, so the rest of the queue can go on.
  private func deferForLostNetwork(_ id: String) -> Bool {
    if NetworkStatusMonitor.shared.isConnected {
      let deferrals = networkDeferrals[id, default: 0] + 1
      guard deferrals <= Self.maxNetworkDeferrals else {
        networkDeferrals[id] = nil
        return false
      }
      networkDeferrals[id] = deferrals
    }
    lastBatchLostNetwork = true
    return true
  }

  /// An export too big for the free space fails at once, instead of filling the device for
  /// minutes and starving the exports of every other item.
  public nonisolated static func requireFreeSpace(
    for bytes: Int64, reserving reservedBytes: Int64 = 0, at directory: URL = FileManager.default.temporaryDirectory
  ) throws {
    try requireFreeSpace(for: bytes, reserving: reservedBytes, available: exportCapacity(at: directory))
  }

  @concurrent
  private nonisolated static func availableExportCapacity() async -> Int64? {
    exportCapacity(at: FileManager.default.temporaryDirectory)
  }

  private nonisolated static func exportCapacity(at directory: URL) -> Int64? {
    let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
    return [values?.volumeAvailableCapacity.map(Int64.init), values?.volumeAvailableCapacityForImportantUsage]
      .compactMap { $0 }.min()
  }

  private nonisolated static func requireFreeSpace(for bytes: Int64, reserving reservedBytes: Int64 = 0, available: Int64?) throws {
    guard let available else { return }
    let margin: Int64 = 200_000_000
    let needed = max(0, bytes).addingReportingOverflow(max(0, reservedBytes))
    guard !needed.overflow, needed.partialValue <= Int64.max - margin else {
      throw GPhotosError.notEnoughSpace(needed: Int64.max)
    }
    if needed.partialValue + margin > available {
      throw GPhotosError.notEnoughSpace(needed: needed.partialValue + margin)
    }
  }

  private nonisolated static func hashFile(
    at url: URL,
    progress: @escaping @Sendable (Int64, Int64) -> Void
  ) async throws -> Data {
    let task = Task.detached(priority: .utility) { @Sendable in
      try GooglePhotosMobileClient.streamSHA1(fileURL: url, onProgress: progress)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  enum ProgressPhase {
    case hashing, uploading

    var status: String {
      switch self {
      case .hashing: "hashing"
      case .uploading: "uploading"
      }
    }

    /// Statuses a late callback of this phase may still overwrite. Anything else means
    /// the item moved on (checked, finalized, finished) and the callback is stale.
    var acceptedStatuses: Set<String> {
      switch self {
      case .hashing: ["hashing"]
      case .uploading: ["hashing", "checking", "uploading"]
      }
    }
  }

  @ObservationIgnored private var pendingWorkerProgress: [Int: (base: WorkerState, latest: WorkerState)] = [:]

  func flushWorkerProgress() {
    var updated = workers
    for (index, pending) in pendingWorkerProgress
    where updated.indices.contains(index) && updated[index] == pending.base {
      updated[index] = pending.latest
    }
    pendingWorkerProgress.removeAll(keepingCapacity: true)
    if updated != workers { workers = updated }
    recalculateOverallProgress()
  }

  /// Applies a progress callback to a worker slot. Callbacks hop to the main actor in
  /// their own tasks, so one can land after the item finished or the slot was reused;
  /// those are dropped. The slot is written once so observers see a single change, and
  /// only when it moved enough to be visible, since every write invalidates the UI.
  func applyProgress(workerID: Int, itemID: String, phase: ProgressPhase, _ update: (inout WorkerState) -> Void) {
    guard workers.indices.contains(workerID),
      workers[workerID].itemID == itemID,
      phase.acceptedStatuses.contains(workers[workerID].status)
    else { return }
    let previous = workers[workerID]
    let pending = pendingWorkerProgress[workerID]
    var state = pending?.base == previous ? pending?.latest ?? previous : previous
    if phase == .uploading && previous.status != "uploading" {
      state.bytesUploaded = 0
      state.resetMetrics()
    }
    state.status = phase.status
    update(&state)
    let now = ProcessInfo.processInfo.systemUptime
    batchProgress.resize(id: itemID, size: state.bytesTotal)
    if phase == .hashing {
      state.bytesUploaded = 0
      state.resetMetrics()
    } else {
      batchProgress.sent(id: itemID, bytes: state.bytesUploaded, at: now)
    }
    if state.status != previous.status || state.message != previous.message {
      pendingWorkerProgress[workerID] = nil
      workers[workerID] = state
      recalculateOverallProgress()
    } else {
      pendingWorkerProgress[workerID] = (previous, state)
    }
  }

  func prepareWorker(_ workerID: Int, for item: UploadQueueItem) {
    pendingWorkerProgress[workerID] = nil
    workers[workerID] = WorkerState(
      id: workerID, itemID: item.id, status: "hashing", filename: item.filename,
      message: "Analyzing media...", bytesTotal: item.fileSize)
    currentFilename = item.filename
  }

  private func notifyFinished(itemID: String, status: TransferStatus) async {
    await onItemFinished?(itemID, status)
    await onItemCompleted?()
  }

  private func confirmSaved(_ saved: Bool, itemID: String) async throws {
    guard saved else { throw GPhotosError.fileReadFailed("Couldn’t save the backup result. Tap Retry.") }
    await notifyFinished(itemID: itemID, status: .sent)
  }

  private func existingAssetCopy(
    of asset: TransferRecord.PreparedAsset, needsMotion: Bool, accountEmail: String, workerID: Int
  ) async throws -> (key: String, motion: String?, foundInAccount: Bool)? {
    let hash = asset.sha1
    guard let sha1 = Data(base64Encoded: hash), sha1.count == 20 else { return nil }
    let motion = asset.motionSHA1
    if needsMotion && motion == nil { return nil }
    workers[workerID].status = "checking"
    workers[workerID].message = "Checking Google Photos…"
    if let copy = await manifestStore.uploadedMediaKey(forSHA1: hash, accountEmail: accountEmail),
      motion == nil || motion == copy.pairedSourceSHA1
    {
      return (copy.mediaKey, motion, copy.foundInAccount)
    }
    guard let key = try await client.findExisting(sha1: sha1) else { return nil }
    if let motion {
      guard let videoSHA1 = Data(base64Encoded: motion), videoSHA1.count == 20,
        try await client.findExisting(sha1: videoSHA1, asLivePhotoMotion: true) != nil
      else { return nil }
    }
    return (key, motion, true)
  }

  private func processItem(item: UploadQueueItem, workerID: Int, quality: Int64) async -> ProcessResult? {
    let exportDirectory = item.assetLocalIdentifier.map { _ in
      LivePhotoManager.exportRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
    let result = await performUpload(item: item, workerID: workerID, quality: quality, exportDirectory: exportDirectory)
    if let exportDirectory {
      await Task.detached(priority: .utility) {
        try? FileManager.default.removeItem(at: exportDirectory)
      }.value
    }
    return result
  }

  private func performUpload(
    item: UploadQueueItem, workerID: Int, quality: Int64, exportDirectory: URL?
  ) async -> ProcessResult? {
    let client = self.client
    let manifest = self.manifestStore
    if Task.isCancelled {
      await manifest.releaseUploadClaim(id: item.id)
      await onItemCompleted?()
      return nil
    }
    let coordinatesPhotoUpload = item.assetLocalIdentifier != nil && claimPhotoUpload != nil
    if coordinatesPhotoUpload, await claimPhotoUpload?(item.id) != true {
      await manifest.releaseUploadClaim(id: item.id)
      await onItemCompleted?()
      return nil
    }
    defer {
      if coordinatesPhotoUpload { releasePhotoUpload?(item.id) }
    }
    if Task.isCancelled {
      await manifest.releaseUploadClaim(id: item.id)
      await onItemCompleted?()
      return nil
    }
    let accountEmail = currentAccountEmail
    let allowsICloudDownloads = iCloudDownloadLimit.map { item.fileSize <= $0 } ?? true
    if PreparationGuard.shared.isSkipped(item.id) {
      // Not counted as a batch failure: the scan queues it again on every pass, and each
      // pass would otherwise send another "didn't upload" notification.
      let persisted = await manifest.updateStatus(
        id: item.id, status: .failed, accountEmail: accountEmail, error: PreparationGuard.skippedMessage)
      if persisted {
        await notifyFinished(itemID: item.id, status: .failed)
      } else {
        await manifest.releaseUploadClaim(id: item.id)
        await onItemCompleted?()
      }
      return nil
    }
    // Export and hashing are where one item can take the process down (memory for a huge
    // file); the transfer after them is ordinary networking, which the user or iOS may end.
    PreparationGuard.shared.begin(item.id)
    defer { PreparationGuard.shared.end(item.id) }
    var didSucceed = false
    var claimedSHA1: String?

    var activeFileURL = item.fileURL
    var activeLiveExport = item.livePhotoExport
    var liveFallbackNote: String?
    var assetVersion: TransferRecord.AssetVersion?

    defer {
      if let claimedSHA1 {
        releaseSHA1(claimedSHA1)
      }
    }

    // Unlinking a multi-GB export is not main-actor work.
    defer {
      var toRemove: [URL] = []
      if item.isTemporaryFile {
        toRemove = [item.fileURL]
      } else if didSucceed, item.removeSourceOnSuccess {
        toRemove = [item.fileURL]
      }
      if let live = item.livePhotoExport, !toRemove.isEmpty {
        toRemove.append(contentsOf: [live.photoURL, live.videoURL])
      }
      if !toRemove.isEmpty {
        // `.sent` is written in batches; a crash after the source is gone but before
        // the record is on disk would leave a pending record with nothing to upload.
        let flushesFirst = didSucceed && item.removeSourceOnSuccess
        Task.detached(priority: .utility) {
          // A failed write is retried on the next pass, which still needs the source.
          if flushesFirst, !(await manifest.flush()) { return }
          for url in toRemove { try? FileManager.default.removeItem(at: url) }
        }
      }
    }

    prepareWorker(workerID, for: item)

    let didStart = await manifest.updateStatus(
      id: item.id, status: .sending, progress: 0.0, transferredBytes: 0, accountEmail: accountEmail)
    guard didStart else {
      await manifest.releaseUploadClaim(id: item.id)
      await onItemCompleted?()
      return nil
    }
    acquirePowerAssertion()
    await onItemCompleted?()

    do {
      if Task.isCancelled || isCancelled { throw CancellationError() }
      #if canImport(Photos)
        if let assetID = item.assetLocalIdentifier, let exportDirectory,
          let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID], options: AssetExportService.allFramesFetchOptions()
          ).firstObject
        {
          let version = AssetExportService.version(of: asset)
          assetVersion = version
          let needsMotion = item.pairLivePhotos && item.resourceRole != .alternatePhoto && LivePhotoManager.isLivePhoto(asset)
          var prepared = await manifest.record(for: item.id)?.preparedAsset
          if let source = item.mirrorSource {
            guard
              source.resourceRole == .uneditedOriginal
                || !version.contentChanged(since: source.assetVersion)
            else { throw GPhotosError.fileReadFailed("Waiting for the edited version to back up to the primary account.") }
            if prepared == nil, let hash = source.sha1 {
              prepared = TransferRecord.PreparedAsset(
                modifiedAt: source.assetModifiedAt, hasAdjustments: source.assetHadAdjustments,
                adjustmentTimestamp: source.assetAdjustmentTimestamp,
                sha1: hash, motionSHA1: source.pairedSourceSHA1)
            }
          }
          if let prepared, let accountEmail,
            item.resourceRole == .uneditedOriginal || !version.contentChanged(since: prepared.version)
          {
            if let copy = try await existingAssetCopy(
              of: prepared, needsMotion: needsMotion, accountEmail: accountEmail, workerID: workerID)
            {
              await manifest.rememberPreparedAsset(id: item.id, asset: prepared)
              didSucceed = await manifest.updateStatus(
                id: item.id, status: .sent, progress: 1, transferredBytes: 0, mediaKey: copy.key,
                sha1: prepared.sha1, pairedSHA1: copy.motion, clearsPairedSHA1: copy.motion == nil,
                accountEmail: accountEmail, foundInAccount: copy.foundInAccount,
                error: "Deduplicated (Already in Google Photos)")
              if didSucceed {
                workers[workerID].status = "skipped"
                await notifyFinished(itemID: item.id, status: .sent)
                uploadLogger.debug("Found in destination account before export: \(item.id, privacy: .private(mask: .hash))")
                return ProcessResult(
                  workerID: workerID, filename: item.filename, mediaKey: copy.key,
                  fileSize: item.fileSize, albumNames: item.albumNames)
              }
              throw GPhotosError.fileReadFailed("Couldn’t save the backup result. Tap Retry.")
            }
            workers[workerID].status = "hashing"
            workers[workerID].message = "Preparing photo…"
          }
          if activeLiveExport == nil && needsMotion {
            uploadLogger.debug("Exporting Live Photo \(item.id, privacy: .private(mask: .hash))")
            try await Self.requireFreeSpace(for: item.fileSize, available: Self.availableExportCapacity())
            try Task.checkCancellation()
            do {
              let live = try await LivePhotoManager.exportLivePhoto(
                asset: asset, unedited: item.resourceRole == .uneditedOriginal,
                allowsNetworkAccess: allowsICloudDownloads, into: exportDirectory)
              activeLiveExport = live
            } catch {
              if Task.isCancelled || isCancelled || error is CancellationError
                || [.cancelled, .iCloudDownloadDeferred].contains(error as? GPhotosError)
              {
                throw error
              }
              let error = AssetExportService.exportError(error)
              if case .notEnoughSpace = error { throw error }
              if error == .networkUnavailable { throw error }
              // The still is worth more than a failed item, so it goes up without its video.
              activeLiveExport = nil
              liveFallbackNote = "Uploaded without motion"
            }
          }
          if activeLiveExport == nil && !FileManager.default.fileExists(atPath: activeFileURL.path) {
            uploadLogger.debug("Exporting asset \(item.id, privacy: .private(mask: .hash))")
            try await Self.requireFreeSpace(for: item.fileSize, available: Self.availableExportCapacity())
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            let target = exportDirectory.appendingPathComponent(UUID().uuidString + "." + item.filename)
            activeFileURL = try await AssetExportService.exportResource(
              asset: asset, role: item.resourceRole, to: target, allowsNetworkAccess: allowsICloudDownloads
            ).0
          }
        }
      #endif
      if Task.isCancelled || isCancelled { throw CancellationError() }

      let mediaURLs = activeLiveExport.map { [$0.photoURL, $0.videoURL] } ?? [activeFileURL]
      let validMedia = await Task.detached(priority: .utility) { [mediaURLs] in
        mediaURLs.allSatisfy { SupportedMediaFormats.isMediaContent(fileURL: $0) }
      }.value
      guard validMedia else { throw GPhotosError.fileReadFailed("This file is not a supported photo or video.") }

      if let live = activeLiveExport {
        let liveCreationDate =
          useFilenameDate
          ? (FilenameDateParser.parseDate(from: live.photoFilename) ?? live.creationDate)
          : live.creationDate
        // Live Photo upload flow
        let liveTotal = live.photoSize + live.videoSize
        let photoProgress: @Sendable (Int64, Int64) -> Void = { [weak self] sent, _ in
          Task { @MainActor in
            self?.applyProgress(workerID: workerID, itemID: item.id, phase: .hashing) {
              $0.message = "Analyzing photo..."
              $0.bytesUploaded = sent
              $0.updateTransferMetrics(currentBytes: sent, totalBytes: liveTotal)
            }
          }
        }
        let photoSHA1: Data
        if let cached = item.cachedSHA1(for: live.photoURL) {
          photoSHA1 = cached
        } else {
          photoSHA1 = try await Self.hashFile(at: live.photoURL, progress: photoProgress)
        }

        let videoProgress: @Sendable (Int64, Int64) -> Void = { [weak self] sent, _ in
          Task { @MainActor in
            self?.applyProgress(workerID: workerID, itemID: item.id, phase: .hashing) {
              $0.message = "Analyzing video..."
              $0.bytesUploaded = live.photoSize + sent
              $0.updateTransferMetrics(currentBytes: live.photoSize + sent, totalBytes: liveTotal)
            }
          }
        }
        let videoSHA1 = try await Self.hashFile(at: live.videoURL, progress: videoProgress)
        PreparationGuard.shared.end(item.id)

        await MainActor.run {
          self.workers[workerID].status = "checking"
          self.workers[workerID].message = "Checking deduplication..."
        }

        // Check local manifest store by SHA-1 first
        let photoB64 = photoSHA1.base64EncodedString()
        let videoB64 = videoSHA1.base64EncodedString()
        if let assetVersion {
          await manifest.rememberPreparedAsset(
            id: item.id,
            asset: .init(
              modifiedAt: assetVersion.modifiedAt, hasAdjustments: assetVersion.hasAdjustments,
              adjustmentTimestamp: assetVersion.adjustmentTimestamp, sha1: photoB64, motionSHA1: videoB64))
        }
        let liveSHA1Key = photoB64 + ":" + videoB64
        guard await waitForSHA1(liveSHA1Key, workerID: workerID) else {
          await manifest.releaseUploadClaim(id: item.id)
          await onItemCompleted?()
          return nil
        }
        claimedSHA1 = liveSHA1Key
        if let accountEmail,
          let existing = await manifest.uploadedMediaKey(forSHA1: photoB64, accountEmail: accountEmail),
          existing.pairedSourceSHA1 == videoSHA1.base64EncodedString()
        {
          await MainActor.run {
            guard self.workers.indices.contains(workerID) else { return }
            self.workers[workerID].status = "skipped"
            self.workers[workerID].message = "In Google Photos (Deduplicated)"
            self.workers[workerID].bytesUploaded = 0
            self.workers[workerID].bytesTotal = item.fileSize
            self.workers[workerID].resetMetrics()
            self.recalculateOverallProgress()
          }
          didSucceed = await manifest.updateStatus(
            id: item.id,
            status: .sent,
            progress: 1.0,
            transferredBytes: 0,
            mediaKey: existing.mediaKey,
            sha1: photoB64,
            pairedSHA1: videoSHA1.base64EncodedString(),
            accountEmail: accountEmail,
            foundInAccount: existing.foundInAccount,
            error: "Deduplicated (Already in Google Photos)"
          )
          try await confirmSaved(didSucceed, itemID: item.id)
          return ProcessResult(
            workerID: workerID, filename: item.filename, mediaKey: existing.mediaKey, fileSize: item.fileSize,
            albumNames: item.albumNames)
        }
        let photoExists = try await client.findExisting(sha1: photoSHA1)
        // Motion attached to the still is only found as a Live Photo motion. A copy of the
        // video uploaded on its own does not make the still a Live Photo, so it is attached
        // when the still is already in the account.
        let videoExists: String? =
          if photoExists != nil {
            try await client.findExisting(sha1: videoSHA1, asLivePhotoMotion: true)
          } else {
            nil
          }

        if let photoKey = photoExists, videoExists != nil {
          await MainActor.run {
            self.workers[workerID].status = "skipped"
            self.workers[workerID].message = "In Google Photos (Live Photo already uploaded)"
            self.workers[workerID].bytesUploaded = 0
            self.workers[workerID].resetMetrics()
            self.recalculateOverallProgress()
          }
          didSucceed = await manifest.updateStatus(
            id: item.id,
            status: .sent,
            progress: 1.0,
            transferredBytes: 0,
            mediaKey: photoKey,
            sha1: photoB64,
            pairedSHA1: videoSHA1.base64EncodedString(),
            accountEmail: accountEmail,
            foundInAccount: true,
            error: "Deduplicated (Live Photo already in Google Photos)"
          )
          try await confirmSaved(didSucceed, itemID: item.id)
          return ProcessResult(
            workerID: workerID, filename: item.filename, mediaKey: photoKey, fileSize: item.fileSize,
            albumNames: item.albumNames)
        }

        if photoExists != nil {
          if videoExists == nil {
            // Reconcile: photo exists remotely, upload video and reconcile into Live Photo
            await MainActor.run {
              self.workers[workerID].status = "uploading"
              self.workers[workerID].message = "Uploading video component..."
              self.workers[workerID].bytesTotal = liveTotal
              self.workers[workerID].bytesUploaded = live.photoSize
              self.workers[workerID].resetMetrics()
              self.batchProgress.resize(id: item.id, size: liveTotal)
              self.batchProgress.creditExisting(id: item.id, bytes: live.photoSize)
            }
            let videoTokenStr = try await client.requestUploadToken(sha1B64: videoSHA1.base64EncodedString(), size: live.videoSize)
            let videoFinalize = try await client.uploadWithScotty(fileURL: live.videoURL, token: videoTokenStr) { [weak self] sent, total in
              Task { @MainActor in
                self?.applyProgress(workerID: workerID, itemID: item.id, phase: .uploading) {
                  $0.updateTransferMetrics(currentBytes: live.photoSize + sent, totalBytes: live.photoSize + total)
                }
              }
            }

            await MainActor.run {
              self.workers[workerID].status = "finalizing"
              self.workers[workerID].message = "Reconciling Live Photo..."
            }
            let key = try await client.reconcileLivePhoto(
              input: LivePhotoReconcileRequest(
                videoToken: videoFinalize,
                fileName: live.videoFilename,
                photoSHA1: photoSHA1,
                videoSHA1: videoSHA1,
                createdAt: liveCreationDate,
                modifiedAt: live.modificationDate,
                storagePolicy: quality == 1 ? 1 : 3
              ))

            await MainActor.run {
              self.workers[workerID].bytesUploaded = 0
              self.workers[workerID].resetMetrics()
              self.recalculateOverallProgress()
            }
            // The still was already in the account, so its quality is not known.
            didSucceed = await manifest.updateStatus(
              id: item.id,
              status: .sent,
              progress: 1.0,
              transferredBytes: item.fileSize,
              mediaKey: key,
              sha1: photoSHA1.base64EncodedString(),
              pairedSHA1: videoSHA1.base64EncodedString(),
              accountEmail: accountEmail,
              foundInAccount: true
            )
            try await confirmSaved(didSucceed, itemID: item.id)
            return ProcessResult(
              workerID: workerID, filename: item.filename, mediaKey: key, fileSize: item.fileSize,
              albumNames: item.albumNames)
          }
        }

        // Upload photo component
        await MainActor.run {
          self.workers[workerID].status = "uploading"
          self.workers[workerID].message = "Uploading photo component..."
          self.workers[workerID].bytesTotal = live.photoSize + live.videoSize
        }
        let photoTokenStr = try await client.requestUploadToken(sha1B64: photoSHA1.base64EncodedString(), size: live.photoSize)
        let photoFinalize = try await client.uploadWithScotty(fileURL: live.photoURL, token: photoTokenStr) { [weak self] sent, _ in
          Task { @MainActor in
            self?.applyProgress(workerID: workerID, itemID: item.id, phase: .uploading) {
              $0.updateTransferMetrics(currentBytes: sent, totalBytes: liveTotal)
            }
          }
        }

        // Upload video component
        await MainActor.run {
          self.workers[workerID].status = "uploading"
          self.workers[workerID].message = "Uploading video component..."
        }
        let videoTokenStr = try await client.requestUploadToken(sha1B64: videoSHA1.base64EncodedString(), size: live.videoSize)
        let videoFinalize = try await client.uploadWithScotty(fileURL: live.videoURL, token: videoTokenStr) { [weak self] sent, _ in
          Task { @MainActor in
            self?.applyProgress(workerID: workerID, itemID: item.id, phase: .uploading) {
              $0.updateTransferMetrics(currentBytes: live.photoSize + sent, totalBytes: liveTotal)
            }
          }
        }

        // Commit linked Live Photo
        await MainActor.run {
          self.workers[workerID].status = "finalizing"
          self.workers[workerID].message = "Committing Live Photo..."
        }
        let key = try await client.commitLivePhoto(
          input: LivePhotoCreateRequest(
            photoToken: photoFinalize,
            videoToken: videoFinalize,
            fileName: live.photoFilename,
            photoSHA1: photoSHA1,
            videoSHA1: videoSHA1,
            createdAt: liveCreationDate,
            modifiedAt: live.modificationDate,
            storagePolicy: quality == 1 ? 1 : 3
          ))

        await MainActor.run {
          self.workers[workerID].status = "completed"
          self.workers[workerID].message = "Uploaded"
          self.workers[workerID].bytesUploaded = 0
          self.workers[workerID].resetMetrics()
          self.recalculateOverallProgress()
        }
        didSucceed = await manifest.updateStatus(
          id: item.id,
          status: .sent,
          progress: 1.0,
          transferredBytes: item.fileSize,
          mediaKey: key,
          sha1: photoSHA1.base64EncodedString(),
          pairedSHA1: videoSHA1.base64EncodedString(),
          accountEmail: accountEmail
        )
        try await confirmSaved(didSucceed, itemID: item.id)
        return ProcessResult(
          workerID: workerID, filename: item.filename, mediaKey: key, fileSize: item.fileSize,
          albumNames: item.albumNames)

      } else {
        // Single file upload flow. Only the still goes up here, so each `.sent` below
        // clears any motion hash left from an earlier paired upload: cleanup reads it as
        // proof that Google Photos holds the video.
        // 1. Check local manifest store by SHA-1 first to avoid network request
        let fileURL = activeFileURL
        let hashProgress: @Sendable (Int64, Int64) -> Void = { [weak self] sent, total in
          Task { @MainActor in
            self?.applyProgress(workerID: workerID, itemID: item.id, phase: .hashing) {
              $0.message = "Analyzing media..."
              $0.bytesUploaded = sent
              $0.updateTransferMetrics(currentBytes: sent, totalBytes: total)
            }
          }
        }
        let sha1: Data
        if let cached = item.cachedSHA1(for: activeFileURL) {
          sha1 = cached
        } else {
          sha1 = try await Self.hashFile(at: fileURL, progress: hashProgress)
        }
        PreparationGuard.shared.end(item.id)
        let sha1B64 = sha1.base64EncodedString()
        if let assetVersion {
          await manifest.rememberPreparedAsset(
            id: item.id,
            asset: .init(
              modifiedAt: assetVersion.modifiedAt, hasAdjustments: assetVersion.hasAdjustments,
              adjustmentTimestamp: assetVersion.adjustmentTimestamp, sha1: sha1B64, motionSHA1: nil))
        }
        guard await waitForSHA1(sha1B64, workerID: workerID) else {
          await manifest.releaseUploadClaim(id: item.id)
          await onItemCompleted?()
          return nil
        }
        claimedSHA1 = sha1B64

        if let accountEmail,
          let existing = await manifest.uploadedMediaKey(forSHA1: sha1B64, accountEmail: accountEmail)
        {
          await MainActor.run {
            self.workers[workerID].status = "skipped"
            self.workers[workerID].message = "In Google Photos (Deduplicated)"
            self.workers[workerID].bytesUploaded = 0
            self.workers[workerID].bytesTotal = item.fileSize
            self.workers[workerID].resetMetrics()
            self.recalculateOverallProgress()
          }
          didSucceed = await manifest.updateStatus(
            id: item.id,
            status: .sent,
            progress: 1.0,
            transferredBytes: 0,
            mediaKey: existing.mediaKey,
            sha1: sha1B64,
            clearsPairedSHA1: true,
            accountEmail: accountEmail,
            foundInAccount: existing.foundInAccount,
            error: "Deduplicated (Already in Google Photos)"
          )
          try await confirmSaved(didSucceed, itemID: item.id)
          return ProcessResult(
            workerID: workerID, filename: item.filename, mediaKey: existing.mediaKey, fileSize: item.fileSize,
            albumNames: item.albumNames)
        }

        // 2. Query remote Google Photos or upload
        workers[workerID].status = "checking"
        workers[workerID].message = "Checking Google Photos…"
        let outcome = try await client.uploadFile(
          at: activeFileURL,
          fileName: item.filename,
          quality: quality,
          useFilenameDate: useFilenameDate,
          creationDate: item.creationDate,
          sha1: sha1,
          onHashingProgress: nil,
          onProgress: { [weak self] sent, total in
            Task { @MainActor in
              self?.applyProgress(workerID: workerID, itemID: item.id, phase: .uploading) {
                $0.message = "Uploading..."
                $0.updateTransferMetrics(currentBytes: sent, totalBytes: total)
              }
            }
          }
        )

        let mediaKey: String
        switch outcome.result {
        case .uploaded(let key):
          mediaKey = key
          await MainActor.run {
            self.workers[workerID].status = "completed"
            self.workers[workerID].message = "Uploaded"
            self.workers[workerID].bytesUploaded = 0
            self.workers[workerID].resetMetrics()
            self.recalculateOverallProgress()
          }
          didSucceed = await manifest.updateStatus(
            id: item.id, status: .sent, progress: 1.0, transferredBytes: item.fileSize, mediaKey: mediaKey, sha1: sha1B64,
            clearsPairedSHA1: true, accountEmail: accountEmail, error: liveFallbackNote)
        case .alreadyExists(let key):
          mediaKey = key
          await MainActor.run {
            self.workers[workerID].status = "skipped"
            self.workers[workerID].message = "In Google Photos (Deduplicated)"
            self.workers[workerID].bytesUploaded = 0
            self.workers[workerID].bytesTotal = item.fileSize
            self.workers[workerID].resetMetrics()
            self.recalculateOverallProgress()
          }
          didSucceed = await manifest.updateStatus(
            id: item.id, status: .sent, progress: 1.0, transferredBytes: 0, mediaKey: mediaKey, sha1: sha1B64,
            clearsPairedSHA1: true, accountEmail: accountEmail, foundInAccount: true,
            error: "Deduplicated (Already in Google Photos)")
        }
        try await confirmSaved(didSucceed, itemID: item.id)
        return ProcessResult(
          workerID: workerID, filename: item.filename, mediaKey: mediaKey, fileSize: item.fileSize,
          albumNames: item.albumNames)
      }
    } catch {
      let error = (error as? CocoaError).map { AssetExportService.exportError($0) } ?? error
      let wasCancelled = Task.isCancelled || isCancelled || error is CancellationError || (error as? GPhotosError) == .cancelled
      // An item held back for its iCloud download is not a failure: it stays pending.
      let lostNetwork =
        (error as? GPhotosError) == .networkUnavailable ? await MainActor.run { self.deferForLostNetwork(item.id) } : false
      let isDeferred = (error as? GPhotosError) == .iCloudDownloadDeferred || lostNetwork
      if wasCancelled || isDeferred {
        await MainActor.run {
          guard self.workers.indices.contains(workerID) else { return }
          self.workers[workerID].status = "idle"
          self.workers[workerID].message = isDeferred ? error.localizedDescription : "Cancelled"
          self.workers[workerID].bytesUploaded = 0
          self.workers[workerID].resetMetrics()
          self.recalculateOverallProgress()
        }
        let persisted = await manifest.updateStatus(
          id: item.id, status: .pending, progress: 0, transferredBytes: 0, accountEmail: accountEmail,
          error: isDeferred ? error.localizedDescription : nil)
        if !persisted { await manifest.releaseUploadClaim(id: item.id) }
        await onItemCompleted?()
        return ProcessResult(
          workerID: workerID, filename: item.filename, mediaKey: nil, fileSize: item.fileSize, albumNames: item.albumNames)
      }
      await MainActor.run {
        if case .notEnoughSpace = error as? GPhotosError { self.lastItemRanOutOfSpace = true }
        self.lastBatchFailedCount += 1
        if Self.isAuthError(error) {
          self.lastBatchAuthErrorEmail = accountEmail
        }
        if (error as? GPhotosError) == .storageFull {
          // No other item can succeed either, so the batch stops here rather than failing
          // each remaining item in turn; those stay pending for the next pass.
          self.lastBatchStorageFullEmail = accountEmail
        }
        guard self.workers.indices.contains(workerID) else { return }
        self.workers[workerID].status = "error"
        self.workers[workerID].message = error.localizedDescription
        self.workers[workerID].bytesUploaded = 0
        self.workers[workerID].resetMetrics()
        self.recalculateOverallProgress()
      }
      // Deferred as long as it can be, on a device that looks online.
      let message =
        (error as? GPhotosError) == .networkUnavailable
        ? "Upload kept failing. Tap Retry." : error.localizedDescription
      let persisted = await manifest.updateStatus(
        id: item.id, status: .failed, accountEmail: accountEmail, error: message)
      if persisted {
        await notifyFinished(itemID: item.id, status: .failed)
      } else {
        await manifest.releaseUploadClaim(id: item.id)
        await onItemCompleted?()
      }
      return ProcessResult(workerID: workerID, filename: item.filename, mediaKey: nil, fileSize: item.fileSize, albumNames: item.albumNames)
    }
  }
}

#if DEBUG
  extension UploadWorkerPool {
    /// Drives the pool's published state through a believable batch so the progress UI
    /// can be reviewed without uploading anything. Nothing touches the network or the
    /// manifest; it loops until the process ends.
    public func startPreviewSimulation() {
      let files: [(String, Int64)] = [
        ("IMG_4021.HEIC", 3_400_000), ("IMG_4022.MOV", 48_000_000), ("DSC_0142.DNG", 26_000_000),
        ("IMG_4023.JPG", 2_100_000), ("Vacation-Highlights.mp4", 180_000_000),
      ]
      isRunning = true
      statusMessage = "Uploading"
      workers = (0..<3).map { WorkerState(id: $0) }
      Task { @MainActor [weak self] in
        while let self {
          batchProgress = BatchUploadProgress()
          for (index, file) in files.enumerated() {
            batchProgress.include(id: String(index), size: file.1)
          }
          batchProgress.sample(at: ProcessInfo.processInfo.systemUptime)
          lastBatchTotalCount = files.count
          lastBatchCompletedCount = 0
          completedItemsBytes = 0
          workers = (0..<3).map { WorkerState(id: $0) }
          var next = 0
          while lastBatchCompletedCount < files.count {
            for index in workers.indices {
              var worker = workers[index]
              if worker.status == "idle" || worker.status == "completed" {
                guard next < files.count else { continue }
                let (name, size) = files[next]
                worker = WorkerState(
                  id: index, itemID: String(next), status: "checking", filename: name,
                  message: "Checking", bytesTotal: size)
                next += 1
              } else if worker.status == "checking" {
                worker.status = "uploading"
                worker.message = "Uploading"
              } else if worker.status == "uploading" {
                let step = max(worker.bytesTotal / 12, 400_000)
                worker.updateTransferMetrics(currentBytes: min(worker.bytesTotal, worker.bytesUploaded + step))
                batchProgress.sent(
                  id: worker.itemID, bytes: worker.bytesUploaded,
                  at: ProcessInfo.processInfo.systemUptime)
                if worker.bytesUploaded >= worker.bytesTotal {
                  worker.status = "finalizing"
                  worker.message = "Finishing"
                }
              } else if worker.status == "finalizing" {
                worker.status = "completed"
                worker.message = "Uploaded"
                batchProgress.complete(id: worker.itemID)
                completedItemsBytes = batchProgress.backedUpBytes
                lastBatchCompletedCount += 1
              }
              workers[index] = worker
            }
            currentFilename = workers.first { $0.status == "uploading" }?.filename
            recalculateOverallProgress()
            try? await Task.sleep(for: .milliseconds(500))
          }
          isRunning = false
          recalculateOverallProgress()
          try? await Task.sleep(for: .seconds(2))
          isRunning = true
        }
      }
    }
  }
#endif
