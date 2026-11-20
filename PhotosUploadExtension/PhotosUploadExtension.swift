import ExtensionFoundation
import Foundation
import GPhotosKit
import Photos
import Synchronization

@main
final class PhotosUploadExtension: PHBackgroundResourceUploadJobExtension {
  private let uploader = BackgroundUploader()
  private let activeRun = Mutex<Task<BackgroundUploader.Outcome, Never>?>(nil)

  required init() {}

  func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
    let uploader = self.uploader
    let work = activeRun.withLock { active -> Task<BackgroundUploader.Outcome, Never>? in
      guard active == nil else { return nil }
      let task = Task { await uploader.run() }
      active = task
      return task
    }
    guard let work else { return .processing }
    let deadline = Task {
      do { try await Task.sleep(for: .seconds(240)) } catch { return }
      work.cancel()
    }
    let outcome = await withTaskCancellationHandler {
      await work.value
    } onCancel: {
      work.cancel()
    }
    deadline.cancel()
    activeRun.withLock { $0 = nil }
    return outcome == .finished ? .completed : .processing
  }

  func willTerminate() async {
    activeRun.withLock { $0?.cancel() }
    BackgroundUploadLog.write("run: iOS is ending the extension")
  }
}
