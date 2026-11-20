import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Picks photos and videos and moves their original files to temporary storage, keeping
/// the names Photos reports so they arrive in Google Photos as recognisable files.
struct PhotoLibraryPicker: UIViewControllerRepresentable {
  /// Called as soon as the user confirms, before originals are loaded.
  let onBegin: @MainActor (Int) -> Void
  /// The loaded files, and a message when some items couldn't be read.
  let onFinish: @MainActor ([URL], String?) -> Void

  func makeUIViewController(context: Context) -> PHPickerViewController {
    var configuration = PHPickerConfiguration()
    configuration.filter = .any(of: [.images, .videos])
    configuration.selectionLimit = 0
    configuration.preferredAssetRepresentationMode = .current
    let controller = PHPickerViewController(configuration: configuration)
    controller.delegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ controller: PHPickerViewController, context: Context) {
    context.coordinator.parent = self
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  @MainActor
  final class Coordinator: NSObject, PHPickerViewControllerDelegate {
    var parent: PhotoLibraryPicker

    init(parent: PhotoLibraryPicker) {
      self.parent = parent
    }

    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
      let providers = results.map(\.itemProvider)
      let count = providers.count
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self.parent.onBegin(count) }
      }
      let pending = PendingProviders(providers)
      let collector = Collector(count: count)
      let group = DispatchGroup()
      for _ in providers { group.enter() }
      // Each finished load starts the next, so no thread ever waits on PhotoKit.
      @Sendable func loadNext() {
        guard let next = pending.next() else { return }
        let index = next.index
        Self.loadOriginal(from: next.provider) { result in
          collector.store(result, at: index)
          group.leave()
          loadNext()
        }
      }
      for _ in 0..<min(count, Self.maxConcurrentLoads) { loadNext() }
      group.notify(queue: .main) {
        MainActor.assumeIsolated {
          let (urls, failure) = collector.result
          self.parent.onFinish(urls, failure)
        }
      }
    }

    /// Each load stages a full-size original, so a large pick opening them all at once
    /// competes for disk and memory with itself.
    nonisolated private static let maxConcurrentLoads = 4

    /// Hands out providers in order to whichever load slot frees up first.
    private final class PendingProviders: @unchecked Sendable {
      private let lock = NSLock()
      private let providers: [NSItemProvider]
      private var nextIndex = 0

      init(_ providers: [NSItemProvider]) {
        self.providers = providers
      }

      func next() -> (index: Int, provider: NSItemProvider)? {
        lock.withLock {
          guard nextIndex < providers.count else { return nil }
          defer { nextIndex += 1 }
          return (nextIndex, providers[nextIndex])
        }
      }
    }

    /// Gathers per-item results from PhotoKit's callback queues.
    private final class Collector: @unchecked Sendable {
      private let lock = NSLock()
      private var urls: [URL?]
      private var failures: [Error] = []

      init(count: Int) {
        urls = Array(repeating: nil, count: count)
      }

      func store(_ result: Result<URL, Error>, at index: Int) {
        lock.withLock {
          switch result {
          case .success(let url): urls[index] = url
          case .failure(let failure): failures.append(failure)
          }
        }
      }

      /// Every item that copied, plus a summary of any that didn't.
      var result: ([URL], String?) {
        lock.withLock {
          let message: String? =
            switch failures.count {
            case 0: nil
            case 1: failures[0].localizedDescription
            default: String(localized: "\(failures.count) items couldn’t be read from Photos.")
            }
          return (urls.compactMap { $0 }, message)
        }
      }
    }

    private struct UnsupportedItem: LocalizedError {
      var errorDescription: String? { String(localized: "The selected item isn’t a supported photo or video.") }
    }

    nonisolated private static let preferredTypes: [UTType] = [.movie, .quickTimeMovie, .heic, .jpeg, .png, .image]

    nonisolated private static func loadOriginal(
      from provider: NSItemProvider, completion: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
      guard let type = preferredTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) })
      else { return completion(.failure(UnsupportedItem())) }
      let suggestedName = provider.suggestedName
      provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
        // The provided file is deleted when this handler returns, so take it now. Moving
        // avoids rewriting a full-size original; copying covers a move that is refused.
        guard let url else { return completion(.failure(error ?? UnsupportedItem())) }
        let directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("GPhotosPicked", isDirectory: true)
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent(
          filename(suggested: suggestedName, fallback: url, type: type))
        do {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          do {
            try FileManager.default.moveItem(at: url, to: destination)
          } catch {
            try FileManager.default.copyItem(at: url, to: destination)
          }
          completion(.success(destination))
        } catch {
          try? FileManager.default.removeItem(at: directory)
          completion(.failure(error))
        }
      }
    }

    /// A single safe path component: no separators, control characters, or dot names.
    nonisolated static func filename(suggested: String?, fallback: URL, type: UTType) -> String {
      let ext = type.preferredFilenameExtension ?? fallback.pathExtension
      let base = (suggested ?? fallback.deletingPathExtension().lastPathComponent)
        .components(separatedBy: "/").last?
        .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        .map(String.init).joined()
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let name = base.isEmpty || base == "." || base == ".." ? "Photo" : base
      return URL(fileURLWithPath: name).pathExtension.isEmpty && !ext.isEmpty ? "\(name).\(ext)" : name
    }
  }
}
