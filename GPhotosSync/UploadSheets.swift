import GPhotosKit
import SwiftUI
import UniformTypeIdentifiers

/// Chooses where manually uploaded media comes from.
struct UploadSourceSheet: View {
  let onPick: (UploadBatch) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var isPickingPhotos = false
  @State private var isPickingFiles = false
  @State private var preparingCount = 0
  @State private var errorMessage: String?
  @State private var contentHeight: CGFloat = 0

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text("Upload Media")
            .font(.title2.weight(.bold))
            .accessibilityAddTraits(.isHeader)
          Spacer()
          Button("Close", systemImage: "xmark") { dismiss() }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .disabled(preparingCount > 0)
        }
        .padding(.bottom, 4)

        if preparingCount > 0 {
          HStack(spacing: 12) {
            ProgressView()
            Text("Preparing ^[\(preparingCount) item](inflect: true) from Photos…")
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, minHeight: 120)
          .tintedSurface()
        } else {
          sourceButton(
            "Photo Library", detail: "Photos and videos from your library", symbol: "photo.on.rectangle",
            colors: [.blue, .cyan]
          ) { isPickingPhotos = true }
          sourceButton(
            "Files", detail: "From iCloud Drive or this iPhone", symbol: "folder.fill", colors: [.orange, .yellow]
          ) { isPickingFiles = true }
        }

        if let errorMessage {
          InlineMessage(errorMessage)
        }
      }
      .padding(20)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
    .scrollBounceBehavior(.basedOnSize)
    .presentationDetents(contentHeight > 0 ? [.height(contentHeight), .large] : [.medium, .large])
    .presentationDragIndicator(.hidden)
    .interactiveDismissDisabled(preparingCount > 0)
    .sheet(isPresented: $isPickingPhotos) {
      PhotoLibraryPicker { count in
        isPickingPhotos = false
        preparingCount = count
      } onFinish: { urls, failure in
        isPickingPhotos = false
        preparingCount = 0
        if urls.isEmpty {
          errorMessage = failure
        } else {
          onPick(UploadBatch(expectedCount: urls.count, files: urls, isPreparing: false, failure: failure))
        }
      }
      .ignoresSafeArea()
    }
    .fileImporter(
      isPresented: $isPickingFiles,
      allowedContentTypes: [.image, .movie, .video],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls):
        if !urls.isEmpty { onPick(UploadBatch(expectedCount: urls.count, files: urls, isPreparing: false)) }
      case .failure(let error):
        errorMessage = error.localizedDescription
      }
    }
  }

  private func sourceButton(
    _ title: LocalizedStringKey, detail: LocalizedStringKey, symbol: String, colors: [Color],
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      SettingRow(title, detail: detail, symbol: symbol, colors: colors) {
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .contentShape(.rect)
    }
    .buttonStyle(PressableButtonStyle())
    .accessibilityHint("Opens the picker")
    .tintedSurface()
  }
}

/// Media picked for a manual upload. Photos picks are confirmed while their originals are
/// still being copied out, so the files arrive after the sheet is already up.
@Observable
@MainActor
final class UploadBatch: Identifiable {
  nonisolated let id = UUID()
  var expectedCount: Int
  var files: [URL]
  var isPreparing: Bool
  var failure: String?

  init(expectedCount: Int, files: [URL], isPreparing: Bool, failure: String? = nil) {
    self.expectedCount = expectedCount
    self.files = files
    self.isPreparing = isPreparing
    self.failure = failure
  }
}

/// Shows what's about to be uploaded and queues it.
struct ConfirmUploadSheet: View {
  let model: AppModel
  let batch: UploadBatch
  @State private var remaining: [URL]
  @State private var didFail = false
  @Environment(\.dismiss) private var dismiss
  @State private var sizes: [URL: Int64] = [:]
  @State private var isSending = false
  @State private var errorMessage: String?
  @State private var contentHeight: CGFloat = 0

  init(model: AppModel, batch: UploadBatch) {
    self.model = model
    self.batch = batch
    _remaining = State(initialValue: batch.files)
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        HStack {
          Spacer()
          Button("Cancel", systemImage: "xmark") { dismiss() }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .disabled(isSending)
        }

        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 48))
          .foregroundStyle(.blue)
          .accessibilityHidden(true)
        VStack(spacing: 4) {
          title
            .font(.headline)
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
          Text(ByteFormat.string(sizes.values.reduce(0, +)))
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
            .redacted(reason: batch.isPreparing ? .placeholder : [])
        }

        if batch.isPreparing {
          HStack(spacing: 12) {
            ProgressView()
            Text("Preparing ^[\(batch.expectedCount) item](inflect: true) from Photos…")
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 16)
          .tintedSurface()
        } else if remaining.count > 1 {
          VStack(spacing: 0) {
            ForEach(remaining, id: \.self) { url in
              if url != remaining.first { Divider().padding(.leading, 16) }
              HStack {
                Text(url.lastPathComponent)
                  .lineLimit(1)
                  .truncationMode(.middle)
                Spacer()
                Text(ByteFormat.string(sizes[url] ?? 0))
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
              .padding(.horizontal, 16)
              .padding(.vertical, 10)
            }
          }
          .tintedSurface()
        }

        if let failure = batch.failure {
          InlineMessage(failure)
        }
        if let errorMessage {
          InlineMessage(errorMessage)
        }

        Button(action: send) {
          HStack(spacing: 8) {
            if isSending { ProgressView() }
            Text(isSending ? "Adding to Queue…" : didFail ? "Retry Failed" : "Upload")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(isSending || batch.isPreparing || remaining.isEmpty)
      }
      .padding(20)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
    .scrollBounceBehavior(.basedOnSize)
    .presentationDetents(contentHeight > 0 ? [.height(contentHeight), .large] : [.medium, .large])
    .presentationDragIndicator(.hidden)
    .interactiveDismissDisabled(isSending)
    .onChange(of: batch.isPreparing) { _, isPreparing in
      if !isPreparing { remaining = batch.files }
    }
    .task(id: batch.files) {
      // Measuring is disk I/O, so it happens once per set of files rather than on every render.
      let files = batch.files
      sizes = await Task.detached(priority: .utility) {
        Dictionary(
          uniqueKeysWithValues: files.map { url in
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            return (url, size ?? 0)
          })
      }.value
    }
  }

  private var title: Text {
    if batch.isPreparing { return Text("^[\(batch.expectedCount) Item](inflect: true)") }
    if remaining.count == 1 { return Text(remaining[0].lastPathComponent) }
    return Text("^[\(remaining.count) Item](inflect: true)")
  }

  private func send() {
    isSending = true
    errorMessage = nil
    Task {
      var failures: [String] = []
      var succeeded: Set<URL> = []
      for url in remaining {
        do {
          let queuedID = try await model.uploadSingleFile(url: url)
          if queuedID == nil, !model.manualUploadNeedsSignIn {
            failures.append(String(localized: "\(url.lastPathComponent): the upload could not start."))
          } else {
            succeeded.insert(url)
          }
        } catch {
          failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
        }
      }
      isSending = false
      if failures.isEmpty {
        dismiss()
      } else {
        remaining.removeAll { succeeded.contains($0) }
        didFail = true
        errorMessage = failures.joined(separator: "\n")
      }
    }
  }
}
