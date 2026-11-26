import GPhotosKit
import Photos
import UIKit

/// The app's side of the photo upload extension, which iOS runs on its own schedule and which
/// keeps backing up the library after the app is closed from the app switcher (iOS 27).
@MainActor
final class BackgroundUploads {
  let uploader = BackgroundUploader()
  var onTransfersFinished: (@MainActor @Sendable () async -> Void)?
  private let store = BackgroundUploadLedgerStore.shared
  private var busyTask: Task<Void, Never>?

  /// Turning the extension on or off is a synchronous call into the Photos service, so it
  /// runs here, in order, instead of holding up launch on the main thread.
  private nonisolated static let extensionQueue = DispatchQueue(label: "BackgroundUploads.extension", qos: .userInitiated)

  /// Turns the extension on or off. iOS requires full library access.
  func setEnabled(_ wanted: Bool) {
    Self.extensionQueue.async { Self.apply(wanted) }
  }

  private nonisolated static func apply(_ wanted: Bool) {
    let library = PHPhotoLibrary.shared()
    guard wanted != library.uploadJobExtensionEnabled else { return }
    do {
      if wanted {
        try library.enableUploadJobExtension(with: nil)
      } else {
        try library.disableUploadJobExtension()
      }
      BackgroundUploadLog.write("app: extension \(wanted ? "on" : "off")")
    } catch {
      BackgroundUploadLog.write("app: couldn't turn the extension \(wanted ? "on" : "off"): \(error)")
    }
  }

  private nonisolated static let ledgerQueue = DispatchQueue(label: "BackgroundUploads.ledger", qos: .utility)
  private var isBusy = false

  nonisolated static func readLedger() async -> BackgroundUploadLedger {
    await withLedger { BackgroundUploadLedgerStore.shared.read() }
  }

  nonisolated static func withLedger<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
      ledgerQueue.async { continuation.resume(returning: work()) }
    }
  }

  func resetAppClaims() {
    Self.ledgerQueue.async {
      BackgroundUploadLedgerStore.shared.update { $0.resetAppClaims() }
    }
  }

  /// Serialize the lease and app claims so a worker never races its own batch's lease.
  func setAppBusy(_ busy: Bool) {
    guard busy != isBusy else { return }
    isBusy = busy
    busyTask?.cancel()
    busyTask = nil
    let store = store
    Self.ledgerQueue.async {
      store.update { ledger in
        if busy { ledger.appWorkEpoch = UUID() }
        ledger.appBusyUntil = busy ? Date().addingTimeInterval(BackgroundUploader.appBusyWindow) : nil
      }
    }
    guard busy else { return }
    busyTask = Task {
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(BackgroundUploader.appBusyWindow / 3)) } catch { return }
        Self.ledgerQueue.async {
          store.update { $0.appBusyUntil = Date().addingTimeInterval(BackgroundUploader.appBusyWindow) }
        }
      }
    }
  }

  nonisolated static func claimForApp(_ recordID: String) async -> Bool {
    await withLedger {
      BackgroundUploadLedgerStore.shared.persist(notifiesAboutWork: false) { $0.claimForApp(recordID) }
    }
  }

  nonisolated static func releaseAppClaim(_ recordID: String) {
    ledgerQueue.async {
      BackgroundUploadLedgerStore.shared.update { $0.releaseAppClaim(recordID) }
    }
  }

  func finishJobs(timeout: Duration) async {
    let work = Task { await uploader.finishJobs() }
    await UploadWorkerPool.wait(timeout: timeout) { await work.value }
    work.cancel()
  }

  /// Retrying failed items includes the ones the extension held back.
  func forgetFailures() async {
    await Self.withLedger { [store] in store.update { $0.failures = [:] } }
  }

  func forgetFailure(of recordID: String) async {
    await Self.withLedger { [store] in store.update { $0.failures[recordID] = nil } }
  }

  // MARK: - Transfers the App Is Woken For

  private var sessions: [String: URLSession] = [:]
  private var completions: [String: [@Sendable () -> Void]] = [:]

  /// iOS launches the app in the background with the outcome of transfers the extension
  /// started, when the extension is gone by then. They go to the ledger, then the session is
  /// let go so it stays free for the extension.
  func handleEvents(forSession identifier: String, completion: @escaping @Sendable () -> Void) -> Bool {
    guard identifier.hasPrefix(BackgroundUploadTransfers.sessionPrefix) else { return false }
    BackgroundUploadLog.write("app: woken for the transfers of \(identifier)")
    completions[identifier, default: []].append(completion)
    guard sessions[identifier] == nil else { return true }
    let delegate = BackgroundUploadTransfers.Delegate(store: store)
    delegate.onFinishedEvents { [weak self] in
      Task { @MainActor in
        guard let self else {
          completion()
          return
        }
        let work = Task { await self.onTransfersFinished?() }
        await UploadWorkerPool.wait(timeout: .seconds(10)) { _ = await work.value }
        work.cancel()
        self.sessions.removeValue(forKey: identifier)?.finishTasksAndInvalidate()
        let callbacks = self.completions.removeValue(forKey: identifier) ?? []
        for callback in callbacks { callback() }
      }
    }
    sessions[identifier] = BackgroundUploadTransfers.session(
      id: identifier, delegate: delegate, meteredAllowed: AppSettingsStore.load().uploadsOnMeteredNetworks)
    return true
  }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
  /// Set by the app before launch finishes.
  @MainActor static var backgroundUploads: BackgroundUploads?

  func applicationWillTerminate(_ application: UIApplication) {
    MainActor.assumeIsolated { LiveActivityController.shared.appWillTerminate() }
  }

  func application(
    _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    // UIKit calls this on the main thread.
    nonisolated(unsafe) let completion = completionHandler
    MainActor.assumeIsolated {
      let handled = Self.backgroundUploads?.handleEvents(forSession: identifier) { completion() } ?? false
      if !handled { completion() }
    }
  }
}
