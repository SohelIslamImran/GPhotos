import SwiftUI

/// The activity list's filters.
public enum ActivityFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
  case all
  case pending
  case uploaded
  case failed

  public var id: Self { self }

  public var title: LocalizedStringKey {
    switch self {
    case .all: "All"
    case .pending: "To Back Up"
    case .uploaded: "Uploaded"
    case .failed: "Failed"
    }
  }

  public var navigationTitle: LocalizedStringKey {
    switch self {
    case .all: "Activity"
    case .pending: "To Back Up"
    case .uploaded: "Uploaded Items"
    case .failed: "Failed Uploads"
    }
  }

  public func includes(_ record: TransferRecord) -> Bool {
    guard !record.isSkipped else { return false }
    return switch self {
    case .all: true
    case .pending: record.status == .pending || record.status == .sending
    case .uploaded: record.isTerminalSuccess
    case .failed: record.status == .failed
    }
  }

  /// Records matching this filter and a free-text query over name, path and error.
  public func apply(to records: [TransferRecord], query: String) -> [TransferRecord] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if self == .all, query.isEmpty, !records.contains(where: \.isSkipped) { return records }
    return records.filter { record in
      guard includes(record) else { return false }
      guard !query.isEmpty else { return true }
      return record.filename.localizedStandardContains(query)
        || (record.sourcePath?.localizedStandardContains(query) ?? false)
        || (record.lastError?.localizedStandardContains(query) ?? false)
    }
  }

  public var emptyTitle: LocalizedStringKey {
    switch self {
    case .all: "No Activity Yet"
    case .pending: "Nothing to Back Up"
    case .uploaded: "Nothing Uploaded Yet"
    case .failed: "No Failed Uploads"
    }
  }

  public var emptySymbol: String {
    switch self {
    case .all: "tray"
    case .pending: "clock"
    case .uploaded: "checkmark.circle"
    case .failed: "exclamationmark.triangle"
    }
  }

  public var emptyDescription: LocalizedStringKey {
    switch self {
    case .all: "Photos and videos you back up appear here with live progress."
    case .pending: "Photos and videos waiting or uploading appear here."
    case .uploaded: "Photos and videos appear here once they’re safely in Google Photos."
    case .failed: "Anything that can’t upload appears here, so you can retry it."
    }
  }

  /// How many of `records` each filter shows, counted in one pass.
  public static func counts(in records: [TransferRecord]) -> [ActivityFilter: Int] {
    var counts: [ActivityFilter: Int] = [:]
    for record in records {
      for filter in allCases where filter.includes(record) {
        counts[filter, default: 0] += 1
      }
    }
    return counts
  }
}

/// The row of glass filter pills above an activity list, each with its live count.
public struct ActivityFilterBar: View {
  @Binding private var selection: ActivityFilter
  private let counts: [ActivityFilter: Int]
  /// Each tab's frame in the bar, so one persistent lens can slide between them. A lens
  /// recreated inside whichever tab is selected snaps instead of moving.
  @State private var tabFrames: [ActivityFilter: CGRect] = [:]
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(selection: Binding<ActivityFilter>, counts: [ActivityFilter: Int]) {
    _selection = selection
    self.counts = counts
  }

  // Touch needs 44pt targets; on the Mac the bar sits with 28pt toolbar controls.
  #if os(macOS)
    private static let tabHeight: CGFloat = 32
    private static let lensInset: CGFloat = 3
    private static let barPadding: CGFloat = 6
  #else
    private static let tabHeight: CGFloat = 44
    private static let lensInset: CGFloat = 4
    private static let barPadding: CGFloat = 8
  #endif

  private var lensAnimation: Animation? {
    reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82)
  }

  /// One glass track with a lens that slides to the selected filter, like the system tab bar.
  public var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 2) {
          ForEach(ActivityFilter.allCases) { filter in
            tab(filter)
              .id(filter)
              .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(Self.space))
              } action: {
                tabFrames[filter] = $0
              }
          }
        }
        .background(alignment: .topLeading) { lens }
        .coordinateSpace(.named(Self.space))
        .padding(.horizontal, 4)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.vertical, Self.barPadding)
      }
      .scrollClipDisabled()
      .accessibilityIdentifier("ActivityFilterBar")
      .onAppear { proxy.scrollTo(selection, anchor: .center) }
      .onChange(of: selection) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
          proxy.scrollTo(selection, anchor: .center)
        }
      }
    }
  }

  nonisolated private static let space = "ActivityFilterBar"

  @ViewBuilder
  private var lens: some View {
    if let frame = tabFrames[selection] {
      Capsule()
        .fill(Color.accentColor.gradient)
        .frame(width: frame.width, height: frame.height - Self.lensInset * 2)
        .offset(x: frame.minX, y: frame.minY + Self.lensInset)
        .animation(lensAnimation, value: selection)
        .animation(lensAnimation, value: frame)
        .allowsHitTesting(false)
    }
  }

  private func tab(_ filter: ActivityFilter) -> some View {
    let isSelected = selection == filter
    let count = counts[filter, default: 0]
    return Button {
      selection = filter
    } label: {
      HStack(spacing: 6) {
        Text(filter.title)
        Text(count, format: .number)
          .monospacedDigit()
          .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
          .contentTransition(reduceMotion ? .identity : .numericText(value: Double(count)))
      }
      // One weight for every tab, so widths don't change while the lens moves.
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      .animation(lensAnimation, value: isSelected)
      .padding(.horizontal, 14)
      .frame(minHeight: Self.tabHeight)
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .opacity(count == 0 && !isSelected && filter != .all ? 0.85 : 1)
    .accessibilityLabel(filter.title)
    .accessibilityValue(Text("^[\(count) item](inflect: true)"))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

extension TransferRecord {
  /// Where this record stands; `isUploading` when a worker is sending it right now.
  public func transferState(isUploading: Bool) -> TransferState {
    if isUploading { return .uploading }
    if wasAlreadyInLibrary { return .onCloud }
    switch status {
    case .sent: return .uploaded
    case .pending, .sending: return .pending
    case .failed: return .failed
    case .deleted: return .removed
    }
  }

  /// Google already had this file, so it was matched rather than uploaded again.
  public var wasAlreadyInLibrary: Bool {
    guard isTerminalSuccess, let note = lastError else { return false }
    return note.contains("Deduplicated") || note.contains("Already in Google")
  }
}

/// One transfer in an activity list. Shared so every platform shows the same facts.
public struct ActivityRow: View {
  private let record: TransferRecord
  private let worker: WorkerState?
  private let waitingReason: String?
  private let onRetry: (() -> Void)?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  /// Increased on a selected Mac list row, whose accent fill would swallow red text.
  @Environment(\.backgroundProminence) private var prominence

  #if os(macOS)
    private let thumbnailSize: CGFloat = 32
  #else
    private let thumbnailSize: CGFloat = 40
  #endif

  public init(record: TransferRecord, worker: WorkerState?, waitingReason: String? = nil, onRetry: (() -> Void)? = nil) {
    self.record = record
    self.worker = worker
    self.waitingReason = waitingReason
    self.onRetry = onRetry
  }

  private var isUploading: Bool {
    worker.map { TransferState(workerStatus: $0.status) == .uploading } == true && waitingReason == nil
  }

  private var state: TransferState { record.transferState(isUploading: isUploading) }

  public var body: some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(spacing: 12))
    HStack(spacing: 12) {
      leadingThumbnail
        .accessibilityHidden(true)

      layout {
        VStack(alignment: .leading, spacing: 3) {
          Text(record.filename)
            .font(.subheadline.weight(.medium))
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            .truncationMode(.middle)
          if !metadata.isEmpty {
            Text(metadata)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
          }
          if record.status == .failed, let error = record.lastError, !error.isEmpty {
            Text(error)
              .font(.caption)
              .foregroundStyle(prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
              .lineLimit(2)
              #if os(macOS)
                .help(error)
              #endif
          }
          if let reason = waitingReason ?? (worker?.status == "waiting" ? worker?.message : nil)
            ?? (state == .pending ? record.lastError : nil)
          {
            Text(reason)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if isUploading, let worker, worker.progress > 0 {
            ProgressView(value: worker.progress)
              .tint(prominence == .increased ? .white : .blue)
              .frame(maxWidth: 180)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        trailing
      }
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .combine)
    .accessibilityActions {
      if let actionTitle, let onRetry {
        Button(actionTitle, action: onRetry)
      }
    }
  }

  @ViewBuilder
  private var leadingThumbnail: some View {
    let shape = RoundedRectangle(cornerRadius: thumbnailSize * 0.22, style: .continuous)
    ZStack {
      // A removed item's source is gone; the view shows its placeholder without loading.
      MediaThumbnailView(record: record, size: thumbnailSize)

      if state == .uploading {
        shape
          .fill(Color.black.opacity(0.35))
          .frame(width: thumbnailSize, height: thumbnailSize)
          .overlay {
            if let worker, worker.progress > 0 {
              ProgressView(value: worker.progress)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.white)
            } else {
              ProgressView()
                .controlSize(.small)
                .tint(.white)
            }
          }
      }
    }
    .frame(width: thumbnailSize, height: thumbnailSize)
    .overlay(alignment: .topTrailing) {
      if state == .failed {
        Image(systemName: "exclamationmark.circle.fill")
          .font(.system(size: 13, weight: .bold))
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, Color.red)
          .offset(x: 3, y: -3)
      }
    }
  }

  @ViewBuilder
  private var trailing: some View {
    #if os(iOS)
      VStack(alignment: .trailing, spacing: 6) { trailingContent }
    #else
      HStack(spacing: 8) { trailingContent }
    #endif
  }

  @ViewBuilder
  private var trailingContent: some View {
    TransferStateBadge(state)
    if let actionTitle, let onRetry {
      Button(actionTitle, action: onRetry)
        .buttonStyle(.bordered)
        #if os(iOS)
          .controlSize(.regular)
        #else
          .controlSize(.small)
        #endif
        .accessibilityLabel(
          state == .failed ? Text("Retry \(record.filename)") : Text("Upload Now \(record.filename)"))
    }
  }

  private var actionTitle: LocalizedStringKey? {
    switch state {
    case .failed: "Retry"
    case .pending: record.status == .pending ? "Upload Now" : nil
    default: nil
    }
  }

  private var metadata: String {
    var parts: [String] = []
    if let bytes = record.byteCount, bytes > 0 { parts.append(ByteFormat.string(bytes)) }
    if let date = record.creationDate ?? record.sentAt { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
    if let worker, !worker.formattedSpeed.isEmpty { parts.append(worker.formattedSpeed) }
    return parts.joined(separator: " · ")
  }
}

/// Where one transfer stands, named, colored and drawn the same in every list and badge.
public enum TransferState: Sendable {
  case uploading
  case pending
  case uploaded
  case onCloud
  case failed
  case removed

  /// A worker's live phase, for surfaces that show the upload pool rather than records.
  public init(workerStatus: String) {
    switch workerStatus {
    case "hashing", "checking", "uploading", "finalizing": self = .uploading
    case "completed": self = .uploaded
    case "skipped": self = .onCloud
    case "error": self = .failed
    default: self = .pending
    }
  }

  public var title: LocalizedStringKey {
    switch self {
    case .uploading: "Uploading"
    case .pending: "Waiting"
    case .uploaded: "Uploaded"
    case .onCloud: "In Cloud"
    case .failed: "Failed"
    case .removed: "Removed"
    }
  }

  public var symbol: String {
    switch self {
    case .uploading: "arrow.up.circle.fill"
    case .pending: "clock.fill"
    case .uploaded: "checkmark.circle.fill"
    case .onCloud: "checkmark.icloud.fill"
    case .failed: "exclamationmark.triangle.fill"
    case .removed: "trash.circle.fill"
    }
  }

  public var tint: Color {
    switch self {
    case .uploading: .blue
    case .pending: .orange
    case .uploaded: .green
    case .onCloud: .green
    case .failed: .red
    case .removed: .secondary
    }
  }
}

/// A small tinted capsule naming a transfer's state. `title` replaces the state's own
/// name with a finer phase, such as "Checking" while uploading.
public struct TransferStateBadge: View {
  private let state: TransferState
  private let title: LocalizedStringKey?
  @Environment(\.backgroundProminence) private var prominence

  public init(_ state: TransferState, title: LocalizedStringKey? = nil) {
    self.state = state
    self.title = title
  }

  public var body: some View {
    let onAccent = prominence == .increased
    Text(title ?? state.title)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(onAccent ? .white : state.tint.mix(with: .primary, by: 0.35))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(onAccent ? .white.opacity(0.22) : state.tint.opacity(0.16), in: .capsule)
      .fixedSize()
  }
}

// MARK: - Now uploading

/// Every file the upload pool is working on, with its thumbnail and progress. Kept as its
/// own view so per-tick progress re-renders only this list.
public struct NowUploadingList: View {
  private let pool: UploadWorkerPool
  private let record: (WorkerState) -> TransferRecord?
  #if os(macOS)
    @ScaledMetric(relativeTo: .subheadline) private var thumbnailSize: CGFloat = 32
  #else
    @ScaledMetric(relativeTo: .subheadline) private var thumbnailSize: CGFloat = 44
  #endif
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// `record` finds the manifest record a worker is sending, for its thumbnail.
  public init(pool: UploadWorkerPool, record: @escaping (WorkerState) -> TransferRecord?) {
    self.pool = pool
    self.record = record
  }

  public var body: some View {
    let workers = pool.workers.filter { !$0.filename.isEmpty && $0.status != "idle" }
    VStack(alignment: .leading, spacing: 8) {
      Text("Uploading")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.leading, 6)
        .accessibilityAddTraits(.isHeader)
      VStack(alignment: .leading, spacing: 14) {
        if workers.isEmpty {
          Text(pool.isBatchFinalizing ? "Finishing backup…" : "Preparing uploads…")
            .foregroundStyle(.secondary)
        }
        // Keyed by the file, not the worker slot, so a new file starts a fresh row
        // instead of animating the previous file's bar backwards.
        ForEach(workers, id: \.rowKey) { worker in
          row(worker)
            .transition(.opacity)
        }
      }
      .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: workers.map(\.rowKey))
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .glassCard()
    }
  }

  /// Every row has the same parts in every phase (name, bar, one line of detail), so a
  /// file moving from checking to uploading to done never changes the list's height.
  private func row(_ worker: WorkerState) -> some View {
    let isUploading = worker.status == "uploading" && worker.bytesTotal > 0
    let phase = Self.phaseTitle(for: worker.status)
    return HStack(spacing: 12) {
      UploadThumbnail(record: record(worker), filename: worker.filename, size: min(thumbnailSize, 64))
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(worker.filename)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer()
          if !isUploading {
            TransferStateBadge(TransferState(workerStatus: worker.status), title: phase)
          }
        }
        Group {
          if isUploading {
            ProgressView(value: worker.progress)
              .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: worker.progress)
          } else if phase != nil {
            // Checking and finishing have no byte progress to show.
            ProgressView().progressViewStyle(.linear)
          } else {
            ProgressView(value: worker.status == "completed" || worker.status == "skipped" ? 1 : 0)
              .opacity(worker.status == "error" ? 0 : 1)
          }
        }
        .accessibilityHidden(!isUploading)
        HStack {
          Text(leadingDetail(worker, isUploading: isUploading))
          Spacer()
          if isUploading {
            Text([worker.formattedETA, worker.formattedSpeed].filter { !$0.isEmpty }.joined(separator: " · "))
          }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func leadingDetail(_ worker: WorkerState, isUploading: Bool) -> String {
    if isUploading {
      return String(localized: "\(ByteFormat.string(worker.bytesUploaded)) of \(ByteFormat.string(worker.bytesTotal))")
    }
    if ["error", "waiting"].contains(worker.status), !worker.message.isEmpty { return worker.message }
    // A space keeps the line's height while there's nothing to say.
    return worker.bytesTotal > 0 ? ByteFormat.string(worker.bytesTotal) : " "
  }

  /// The finer step of an upload in progress; settled states use their shared names.
  private static func phaseTitle(for status: String) -> LocalizedStringKey? {
    switch status {
    case "hashing": "Preparing"
    case "checking": "Checking"
    case "finalizing": "Finishing"
    default: nil
    }
  }
}
