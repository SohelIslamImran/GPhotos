import BackgroundTasks
import Foundation
import GPhotosKit

/// Keeps an upload batch running after the app leaves the foreground, through an iOS
/// continued-processing task. Without one, iOS suspends the app about 30 seconds after it
/// leaves the foreground and the batch stops. iOS shows the task's progress itself and lets
/// the user cancel it there.
///
/// iOS accepts the request only while the app is in the foreground, so it is submitted when
/// a batch starts, and the task runs until the batch finishes.
@MainActor
final class ContinuedUploadSession {
  static let identifierPrefix = "org.gphotosapp.gphotos.continued-upload."
  static let title = "Backing up to Google Photos"
  private static let heartbeatInterval: Duration = .seconds(5)
  /// How long iOS gets to start a submitted task before the request is given up.
  private static let launchTimeout: Duration = .seconds(10)

  /// iOS started the task; from here the batch keeps running in the background.
  var onStarted: (() -> Void)?
  /// iOS ended the task before the batch finished: the user cancelled it, or the system
  /// needed the resources back.
  var onExpired: (() -> Void)?

  /// Submitted, or running.
  var isActive: Bool { identifier != nil }
  /// iOS started the task, so the batch keeps running in the background.
  var isRunning: Bool { task != nil }

  private var identifier: String?
  private var task: BGContinuedProcessingTask?
  private var heartbeat: Task<Void, Never>?
  private var launchWatchdog: Task<Void, Never>?
  private var reported: Int64 = 0
  private var fraction: Double = 0
  private var totalItems = 0
  private var subtitle = ""

  func start(totalItems: Int, subtitle: String) {
    guard !isActive else { return }
    // Each task gets its own identifier: registering one twice is fatal, and registration
    // of a continued-processing identifier is allowed after launch.
    let identifier = Self.identifierPrefix + UUID().uuidString
    // `@Sendable` keeps the handler off the main actor: iOS calls it on its own queue, and a
    // main-actor closure there fails Swift's isolation check and crashes.
    let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) {
      @Sendable [weak self] task in
      guard let continued = task as? BGContinuedProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }
      // BGTask is not Sendable, but its methods are safe from any thread.
      nonisolated(unsafe) let task = continued
      // Installed before the hop to the main actor, so an expiry inside the gap is not lost.
      task.expirationHandler = { [weak self] in
        Task { @MainActor in self?.expired(identifier: identifier) }
      }
      Task { @MainActor [weak self] in
        guard let self, self.identifier == identifier else {
          task.expirationHandler = nil
          task.setTaskCompleted(success: false)
          return
        }
        self.adopt(task)
      }
    }
    guard registered else {
      BackgroundUploadLog.write("continued upload: registration failed")
      return
    }
    let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: Self.title, subtitle: subtitle)
    // Run now or not at all: a request iOS queued could start after the batch is over.
    request.strategy = .fail
    self.identifier = identifier
    self.totalItems = totalItems
    self.subtitle = subtitle
    fraction = 0
    reported = 0
    TaskRequests.submit(request) { @Sendable [weak self] error in
      guard error != nil else { return }
      Task { @MainActor [weak self] in self?.launchTimedOut(identifier: identifier) }
    }
    launchWatchdog = Task { [weak self] in
      try? await Task.sleep(for: Self.launchTimeout)
      guard !Task.isCancelled else { return }
      self?.launchTimedOut(identifier: identifier)
    }
  }

  func update(fraction: Double, totalItems: Int, subtitle: String) {
    self.fraction = fraction
    self.totalItems = totalItems
    report(heartbeat: false)
    guard subtitle != self.subtitle else { return }
    self.subtitle = subtitle
    task?.updateTitle(Self.title, subtitle: subtitle)
  }

  func finish(success: Bool) {
    if let identifier, task == nil { TaskRequests.cancel(identifier) }
    heartbeat?.cancel()
    heartbeat = nil
    launchWatchdog?.cancel()
    launchWatchdog = nil
    if task == nil, let identifier { TaskRequests.cancel(identifier) }
    let task = self.task
    self.task = nil
    identifier = nil
    task?.expirationHandler = nil
    task?.setTaskCompleted(success: success)
  }

  private func adopt(_ task: BGContinuedProcessingTask) {
    launchWatchdog?.cancel()
    launchWatchdog = nil
    self.task = task
    task.updateTitle(Self.title, subtitle: subtitle)
    report(heartbeat: false)
    onStarted?()
    heartbeat = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.heartbeatInterval)
        guard !Task.isCancelled else { return }
        self?.report(heartbeat: true)
      }
    }
  }

  private func report(heartbeat: Bool) {
    guard let task else { return }
    reported = ContinuedUploadProgress.nextReported(
      after: reported, fraction: fraction, totalItems: totalItems, heartbeat: heartbeat)
    task.progress.totalUnitCount = max(1, Int64(totalItems)) * ContinuedUploadProgress.unitsPerItem
    task.progress.completedUnitCount = reported
  }

  private func launchTimedOut(identifier: String) {
    guard self.identifier == identifier, task == nil else { return }
    finish(success: false)
  }

  private func expired(identifier: String) {
    guard self.identifier == identifier else { return }
    finish(success: false)
    onExpired?()
  }
}
