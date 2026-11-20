#if os(macOS)
  import Cocoa
  import CoreGraphics
  import Foundation
  import GPhotosKit
  import IOKit.ps
  import os

  private let logger = Logger(subsystem: "org.gphotosapp.gphotos.mac", category: "MacMirrorScheduler")

  @MainActor
  public final class MacMirrorScheduler {
    public static let shared = MacMirrorScheduler()

    private var scheduler: NSBackgroundActivityScheduler?
    private weak var store: MacSyncStore?
    private var monitorTask: Task<Void, Never>?

    private init() {}

    public func start(store: MacSyncStore) {
      self.store = store
      guard scheduler == nil else { return }

      let sched = NSBackgroundActivityScheduler(identifier: "org.gphotosapp.gphotos.mirror")
      sched.repeats = true
      sched.interval = 30 * 60  // 30 min
      sched.tolerance = 10 * 60  // 10 min
      sched.qualityOfService = .utility

      sched.schedule { [weak self] completion in
        guard let self else {
          completion(.deferred)
          return
        }
        Task { @MainActor in
          guard self.canRunMirror() else {
            completion(.deferred)
            return
          }

          self.startAbortMonitor()
          await self.store?.accountMirror.runIdleWindow()
          self.stopAbortMonitor()
          completion(.finished)
        }
      }
      self.scheduler = sched
    }

    public func canRunMirror() -> Bool {
      guard let store else { return false }
      guard store.accountMirror.hasPendingWork else { return false }
      guard !store.workerPool.isRunning else { return false }
      guard Self.powerAndNetworkAllowMirror(requiresPower: store.settings.copiesOnlyWhileCharging) else { return false }
      guard userIdleSeconds() >= 300 else { return false }
      return true
    }

    nonisolated static func powerAndNetworkAllowMirror(requiresPower: Bool) -> Bool {
      !ProcessInfo.processInfo.isLowPowerModeEnabled && !NetworkStatusMonitor.shared.isExpensive
        && (!requiresPower || isACPowerConnected())
    }

    private nonisolated static func isACPowerConnected() -> Bool {
      // A Copy function: the dictionary is owned here and must be released.
      if IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() != nil {
        return true
      }
      guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
        let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
      else {
        return true
      }
      if sources.isEmpty {
        return true
      }
      for source in sources {
        if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
          let state = desc[kIOPSPowerSourceStateKey as String] as? String
        {
          if state == (kIOPSACPowerValue as String) {
            return true
          }
        }
      }
      return false
    }

    private func userIdleSeconds() -> TimeInterval {
      if let eventType = CGEventType(rawValue: ~0) {
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: eventType)
      }
      return 0
    }

    private func startAbortMonitor() {
      stopAbortMonitor()
      monitorTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(30))
          guard let self else { break }
          guard let store = self.store else { break }
          if store.workerPool.isRunning || self.userIdleSeconds() < 300 {
            logger.info("Aborting mirror window due to user activity or primary upload")
            store.accountMirror.pauseAll()
            break
          }
        }
      }
    }

    private func stopAbortMonitor() {
      monitorTask?.cancel()
      monitorTask = nil
    }
  }
#endif
