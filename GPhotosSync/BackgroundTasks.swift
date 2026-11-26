import BackgroundTasks
import GPhotosKit
import UIKit

enum BackgroundTaskIdentifiers {
  static let refresh = "org.gphotosapp.gphotos.refresh"
  static let processing = "org.gphotosapp.gphotos.processing"
  static let mirror = "org.gphotosapp.gphotos.mirror"
}

/// Calls `setTaskCompleted` once, from either the work or the expiration handler.
private final class BackgroundFinishGate: @unchecked Sendable {
  private let task: BGTask
  private let lock = NSLock()
  private var finished = false
  private var completing = false
  private var expired = false

  init(_ task: BGTask) {
    self.task = task
  }

  /// True for the first caller only, so the wind-down runs once when the work and the
  /// expiration handler both try to complete the task.
  func beginCompletion() -> Bool {
    lock.withLock {
      guard !completing else { return false }
      completing = true
      return true
    }
  }

  func expire() {
    lock.withLock { expired = true }
  }

  func finish(success: Bool) {
    let result: Bool? = lock.withLock {
      guard !finished else { return nil }
      finished = true
      return success && !expired
    }
    if let result { task.setTaskCompleted(success: result) }
  }
}

enum BackgroundTaskRegistrar {
  /// How long expiration may spend winding the batch down before reporting completion.
  private static let expirationGrace: Duration = .milliseconds(1500)

  private enum BackupPass {
    case scheduled(BackgroundFinishGate)
    case shortcut
  }

  @MainActor private static var activeBackupPass: BackupPass?

  /// Registers the handlers against the app-wide model, so a background launch and the
  /// UI share one upload pool and one manifest view.
  static func register(model: AppModel) {
    register(BackgroundTaskIdentifiers.refresh) { task in
      scheduleAppRefresh()
      run(task, model: model, iCloudDownloadLimit: 25_000_000)
    }
    register(BackgroundTaskIdentifiers.processing) { task in
      submitProcessing()
      run(task, model: model, iCloudDownloadLimit: nil)
    }
    register(BackgroundTaskIdentifiers.mirror) { task in
      Task { @MainActor in scheduleMirror(for: model) }
      runMirror(task, model: model)
    }
  }

  private static func register(_ identifier: String, handler: @escaping @Sendable (BGTask) -> Void) {
    if !BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil, launchHandler: handler) {
      BackgroundUploadLog.write("background task: could not register \(identifier)")
    }
  }

  private static func run(_ task: BGTask, model: AppModel, iCloudDownloadLimit: Int64?) {
    let gate = BackgroundFinishGate(task)
    let work = Task { @MainActor in
      guard !Task.isCancelled else { return }
      guard activeBackupPass == nil else {
        gate.finish(success: true)
        return
      }
      activeBackupPass = .scheduled(gate)
      if !model.continuedUpload.isRunning { model.workerPool.iCloudDownloadLimit = iCloudDownloadLimit }
      model.workerPool.holdThroughBackgroundExpiration()
      await model.runBackgroundPass()
      guard !Task.isCancelled else { return }
      await model.workerPool.waitForCurrentBatch()
      guard !Task.isCancelled else { return }
      await model.runCleanupMaintenance()
      guard !Task.isCancelled else { return }
      await complete(model, gate: gate, success: true)
    }

    task.expirationHandler = {
      gate.expire()
      work.cancel()
      Task { @MainActor in
        await complete(model, gate: gate, success: false)
      }
    }
  }

  /// An App Intent gets about 30 seconds in the background; the pass stops in time to wind
  /// down inside it.
  private static let shortcutBudget: Duration = .seconds(22)

  /// A pass for the Back Up Photos shortcut, bounded like a refresh window. Returns what to
  /// tell the user.
  @MainActor
  static func runShortcutPass(model: AppModel) async -> String {
    guard activeBackupPass == nil else { return "A backup is already running." }
    activeBackupPass = .shortcut
    defer { activeBackupPass = nil }
    await model.refreshRecords()
    let sentBefore = model.accountTransferredCount
    let inBackground = UIApplication.shared.applicationState != .active
    // Like a refresh window, too short to download a video from iCloud. A batch already
    // carried on by a continued task, or under a background task's own limit, is left alone.
    let setsLimit = inBackground && !model.continuedUpload.isRunning && model.workerPool.iCloudDownloadLimit == nil
    if setsLimit { model.workerPool.iCloudDownloadLimit = 25_000_000 }
    let work = Task { @MainActor in
      await model.runBackgroundPass()
      await model.workerPool.waitForCurrentBatch()
    }
    await UploadWorkerPool.wait(timeout: shortcutBudget) { await work.value }
    work.cancel()
    if setsLimit { model.workerPool.iCloudDownloadLimit = nil }
    if inBackground {
      await windDown(model)
      await model.prepareForBackground()
      if !model.continuedUpload.isRunning { PreparationGuard.shared.forgetInFlight() }
      await scheduleProcessing(for: model)
    }
    await model.refreshRecords()
    guard model.selectedAccount != nil else { return "Open GPhotos and sign in to back up." }
    let backedUp = max(0, model.accountTransferredCount - sentBefore)
    let waiting = model.accountQueuedCount + model.accountUploadingCount
    let done = backedUp == 1 ? "Backed up 1 item." : "Backed up \(backedUp.formatted()) items."
    guard waiting > 0 else { return backedUp > 0 ? done : "Everything is backed up." }
    return "\(done) \(waiting.formatted()) still waiting."
  }

  private static func runMirror(_ task: BGTask, model: AppModel) {
    let gate = BackgroundFinishGate(task)
    let work = Task { @MainActor in
      await model.accountMirror.runIdleWindow()
      scheduleMirror(for: model)
      gate.finish(success: !Task.isCancelled)
    }

    task.expirationHandler = {
      gate.expire()
      work.cancel()
      Task { @MainActor in
        model.accountMirror.pauseAll()
        scheduleMirror(for: model)
        gate.finish(success: false)
      }
    }
  }

  @MainActor
  private static func complete(
    _ model: AppModel,
    gate: BackgroundFinishGate,
    success: Bool
  ) async {
    guard gate.beginCompletion() else { return }
    guard case .scheduled(let owner) = activeBackupPass, owner === gate else {
      gate.finish(success: success)
      return
    }
    model.workerPool.iCloudDownloadLimit = nil
    model.workerPool.releaseBackgroundExpirationHold()
    await windDown(model)
    await model.prepareForBackground()
    if UIApplication.shared.applicationState == .background, !model.continuedUpload.isRunning {
      PreparationGuard.shared.forgetInFlight()
    }
    await scheduleProcessing(for: model)
    scheduleMirror(for: model)
    activeBackupPass = nil
    gate.finish(success: success)
  }

  /// Cancelling returns in-flight items to the queue cleanly; leaving them running into
  /// suspension would fail them on a dropped connection instead. The user's own stop
  /// state is left alone so foreground auto-sync still resumes the work.
  @MainActor
  private static func windDown(_ model: AppModel) async {
    // A continued task started from the foreground owns the batch and ends it itself.
    guard UIApplication.shared.applicationState == .background, model.isRunning,
      !model.continuedUpload.isRunning
    else { return }
    model.workerPool.cancel()
    await model.workerPool.waitForCurrentBatch(timeout: expirationGrace)
  }

  static func scheduleAppRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskIdentifiers.refresh)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    TaskRequests.submit(request)
  }

  @MainActor
  static func scheduleProcessingOnBackground(for model: AppModel) {
    if model.hasKnownBackgroundWork {
      submitProcessing()
      return
    }

    var assertion = UIBackgroundTaskIdentifier.invalid
    var work: Task<Void, Never>?
    func endAssertion() {
      guard assertion != .invalid else { return }
      UIApplication.shared.endBackgroundTask(assertion)
      assertion = .invalid
    }
    assertion = UIApplication.shared.beginBackgroundTask(withName: "Schedule photo backup") {
      MainActor.assumeIsolated {
        work?.cancel()
        submitProcessing()
        endAssertion()
      }
    }
    guard assertion != .invalid else {
      // We cannot wait for the ledger before suspension.
      submitProcessing()
      return
    }
    work = Task {
      await scheduleProcessing(for: model)
      endAssertion()
    }
  }

  /// Withdraws an earlier request when nothing is left, so the system doesn't wake the
  /// app for an empty pass.
  @MainActor
  static func scheduleProcessing(for model: AppModel) async {
    let hasWork = await model.hasPendingBackgroundWork()
    guard !Task.isCancelled else { return }
    if hasWork {
      submitProcessing()
    } else {
      TaskRequests.cancel(BackgroundTaskIdentifiers.processing)
    }
  }

  private static func submitProcessing() {
    let request = BGProcessingTaskRequest(identifier: BackgroundTaskIdentifiers.processing)
    request.requiresNetworkConnectivity = true
    request.requiresExternalPower = false
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    TaskRequests.submit(request)
  }

  @MainActor
  static func scheduleMirror(for model: AppModel) {
    guard model.accountMirror.hasPendingWork else {
      TaskRequests.cancel(BackgroundTaskIdentifiers.mirror)
      return
    }
    submitMirror(requiresPower: model.settings.copiesOnlyWhileCharging)
  }

  private static func submitMirror(requiresPower: Bool) {
    let request = BGProcessingTaskRequest(identifier: BackgroundTaskIdentifiers.mirror)
    request.requiresNetworkConnectivity = true
    request.requiresExternalPower = requiresPower
    request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
    TaskRequests.submit(request)
  }
}

/// Submits and cancels task requests off the main thread, as iOS asks; one queue keeps them
/// in the order they were made, so a cancel never overtakes the submit before it.
enum TaskRequests {
  private static let queue = DispatchQueue(label: "org.gphotosapp.gphotos.task-requests", qos: .utility)

  static func submit(
    _ request: BGTaskRequest,
    completion: @escaping @Sendable (Error?) -> Void = { error in
      if let error { BackgroundUploadLog.write("background task: submit failed: \(error)") }
    }
  ) {
    // Not changed after this point; only the queue reads it.
    nonisolated(unsafe) let request = request
    queue.async { BGTaskScheduler.shared.submitTaskRequest(request, completionHandler: completion) }
  }

  static func cancel(_ identifier: String) {
    queue.async { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
  }
}
