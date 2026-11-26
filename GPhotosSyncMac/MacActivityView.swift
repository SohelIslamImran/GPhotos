import AppKit
import GPhotosKit
import SwiftUI

/// Every upload for the account, as a sortable table. Each row is one line of fixed
/// height, and live progress is drawn inside its Status cell, so nothing moves as files
/// start, progress and finish.
struct MacActivityView: View {
  let store: MacSyncStore
  let router: MacRouter
  @Binding var filter: ActivityFilter
  @State private var query = ""
  /// The query the rows are filtered by, a moment after typing pauses, so each keystroke
  /// doesn't filter the whole history again.
  @State private var appliedQuery = ""
  @FocusState private var isSearchFocused: Bool
  @State private var selection = Set<TransferRecord.ID>()
  /// Empty until a column header is clicked: the manifest's own order, which needs no sort.
  @State private var sortOrder: [KeyPathComparator<TransferRecord>] = []
  /// The rows last shown, so a selection change doesn't filter and sort them again.
  @State private var rows = NativeActivityTable.Rows([])
  @State private var renderedAccount: String?

  private struct RowRequest: Equatable {
    let revision: Int
    let account: String?
    let filter: ActivityFilter
    let query: String
    let sortOrder: [KeyPathComparator<TransferRecord>]
  }

  private var rowRequest: RowRequest {
    RowRequest(
      revision: store.accountActivityRevision, account: store.selectedAccount?.email, filter: filter,
      query: appliedQuery, sortOrder: sortOrder)
  }

  var body: some View {
    let request = rowRequest
    let visible = renderedAccount == request.account ? rows : .empty
    table(visible)
      .transaction { $0.animation = nil }
      .overlay {
        if visible.records.isEmpty {
          emptyState
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .searchable(text: $query, placement: .toolbar, prompt: "Search activity")
      .searchFocused($isSearchFocused)
      .onChange(of: router.focusSearch, initial: true) { _, wanted in
        guard wanted else { return }
        isSearchFocused = true
        router.focusSearch = false
      }
      // A hidden row must not stay selected, or Copy and Retry act on what isn't shown.
      .onChange(of: filter) { selection.removeAll() }
      .task(id: query) {
        // Clearing the field shows everything again at once.
        if !query.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
        guard !Task.isCancelled else { return }
        appliedQuery = query
      }
      .onChange(of: request.account) { selection.removeAll() }
      .task(id: request) {
        let records = store.activityRecords(for: request.account)
        let work = Task.detached(priority: .userInitiated) {
          let filtered = request.filter.apply(to: records, query: request.query)
          guard !Task.isCancelled else { return NativeActivityTable.Rows.empty }
          let sorted = request.sortOrder.isEmpty ? filtered : filtered.sorted(using: request.sortOrder)
          return NativeActivityTable.Rows(sorted)
        }
        let next = await withTaskCancellationHandler {
          await work.value
        } onCancel: {
          work.cancel()
        }
        guard !Task.isCancelled, request == rowRequest else { return }
        selection = selection.filter { next.indexByID[$0] != nil }
        renderedAccount = request.account
        rows = next
      }
      .navigationTitle("Activity")
      .navigationSubtitle(subtitle)
      .toolbar { toolbar }
  }

  /// Counts live in the subtitle rather than in the filter's segments, whose widths would
  /// otherwise change as they tick.
  private var subtitle: String {
    let counts = store.accountRecordCounts
    var parts: [String] = []
    let inProgress = counts.uploading + counts.queued
    if inProgress > 0 { parts.append(String(localized: "\(inProgress.formatted()) in progress")) }
    parts.append(String(localized: "\(counts.sent.formatted()) uploaded"))
    if counts.failed > 0 { parts.append(String(localized: "\(counts.failed.formatted()) failed")) }
    return parts.joined(separator: " · ")
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .principal) {
      Picker("Show", selection: $filter) {
        ForEach(ActivityFilter.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .help("Show uploads by state")
    }
    // Always there, so the toolbar doesn't rearrange when the first upload fails.
    ToolbarItem(placement: .primaryAction) {
      Button("Retry Failed", systemImage: "arrow.clockwise") { Task { await store.retryFailedForUser() } }
        .help("Retry every failed upload")
        .disabled(store.isRunning || !store.hasFailedRecords)
    }
  }

  @ViewBuilder private var emptyState: some View {
    if query.isEmpty {
      ContentUnavailableView(
        filter.emptyTitle, systemImage: filter.emptySymbol, description: Text(filter.emptyDescription))
    } else {
      ContentUnavailableView {
        Label("No Results", systemImage: "magnifyingglass")
      } description: {
        Text(filter == .all ? "No activity matches “\(query)”." : "Nothing in this filter matches “\(query)”.")
      } actions: {
        if filter != .all { Button("Show All") { filter = .all } }
      }
    }
  }

  private func table(_ visible: NativeActivityTable.Rows) -> some View {
    NativeActivityTable(
      rows: visible, selection: $selection,
      cell: { record, column in AnyView(cell(record, column: column).id(record.id)) },
      sortChanged: { descriptors in
        sortOrder = descriptors.compactMap { descriptor in
          let order: SortOrder = descriptor.ascending ? .forward : .reverse
          return switch descriptor.key {
          case "name": KeyPathComparator(\TransferRecord.filename, order: order)
          case "status": KeyPathComparator(\TransferRecord.statusRank, order: order)
          case "size": KeyPathComparator(\TransferRecord.sortableSize, order: order)
          case "date": KeyPathComparator(\TransferRecord.sortableDate, order: order)
          default: nil
          }
        }
      },
      menu: { NSHostingMenu(rootView: menu(for: $0)) },
      primaryAction: { records in
        let urls = records.compactMap(fileURL)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
      }
    )
    .onCopyCommand {
      selection.compactMap { visible.indexByID[$0] }.sorted().map {
        NSItemProvider(object: visible.records[$0].filename as NSString)
      }
    }
  }

  @ViewBuilder
  private func cell(_ record: TransferRecord, column: NativeActivityTable.Column) -> some View {
    switch column {
    case .name:
      HStack(spacing: 8) {
        MediaThumbnailView(record: record, size: 22).accessibilityHidden(true)
        Text(record.filename).lineLimit(1).truncationMode(.middle)
      }
      .help(record.sourcePath.map(abbreviatedHomePath) ?? record.filename)
    case .status: ActivityStatusCell(store: store, record: record)
    case .size:
      Text(record.byteCount.map { ByteFormat.string($0) } ?? "—")
        .monospacedDigit().foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
    case .date:
      Text((record.creationDate ?? record.sentAt).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
        .monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
    case .details: ActivityDetailCell(store: store, record: record)
    }
  }

  private func fileURL(_ record: TransferRecord) -> URL? {
    record.sourcePath.map { URL(fileURLWithPath: $0) }
  }

  @ViewBuilder
  private func menu(for records: [TransferRecord]) -> some View {
    let urls = records.compactMap(fileURL)
    let resendable = records.filter { $0.status == .failed || $0.status == .pending }
    if !resendable.isEmpty {
      Button(
        resendable.allSatisfy { $0.status == .pending } ? "Upload Now" : "Retry", systemImage: "arrow.clockwise"
      ) {
        for record in resendable {
          Task { await store.resendRecord(record) }
        }
      }
      Divider()
    }
    let failed = records.filter { $0.status == .failed }
    if !failed.isEmpty {
      Button("Skip Future Uploads", systemImage: "forward.end") {
        Task { await store.skipFailedRecords(failed.map(\.id)) }
      }

      Divider()
    }
    if !urls.isEmpty {
      Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
      Button("Open File", systemImage: "arrow.up.forward.app") { for url in urls { NSWorkspace.shared.open(url) } }
      Divider()
    }
    if !records.isEmpty {
      Button("Copy File Name", systemImage: "doc.on.doc") { copy(records.map(\.filename)) }
    }
    if !urls.isEmpty {
      Button("Copy File Path", systemImage: "link") { copy(urls.map(\.path)) }
    }
    if let error = records.first?.lastError, records.count == 1, records.first?.status == .failed {
      Button("Copy Error", systemImage: "exclamationmark.bubble") { copy([error]) }
    }
  }

  private func copy(_ lines: [String]) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
  }
}

extension TransferRecord {
  /// The date the Date column shows; records with neither date sort last.
  fileprivate var sortableDate: Date { creationDate ?? sentAt ?? .distantPast }
  fileprivate var sortableSize: Int64 { byteCount ?? 0 }
  /// Needs attention first: failed, then sending, waiting, done.
  fileprivate var statusRank: Int {
    switch status {
    case .failed: 0
    case .sending: 1
    case .pending: 2
    case .sent: 3
    case .deleted: 4
    }
  }
}

/// The state badge, or a progress bar of the same height while the file uploads. Reads
/// its own worker, so per-tick progress re-renders this cell rather than the table.
private struct ActivityStatusCell: View {
  let store: MacSyncStore
  let record: TransferRecord
  @Environment(\.backgroundProminence) private var prominence

  var body: some View {
    let worker = record.status == .sending ? store.activeWorker(for: record.id, filename: record.filename) : nil
    let state = record.transferState(
      isUploading: worker != nil && !store.isOffline && !store.isWaitingForUnmeteredNetwork
        && !store.workerPool.isRateLimited)
    HStack(spacing: 8) {
      if state == .uploading, let worker, worker.progress > 0 {
        ProgressView(value: worker.progress)
          .progressViewStyle(.linear)
          .controlSize(.small)
          .tint(prominence == .increased ? .white : .accentColor)
          .frame(width: 72)
        Text(worker.progress, format: .percent.precision(.fractionLength(0)))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      } else {
        TransferStateBadge(state)
      }
      Spacer(minLength: 0)
      if record.status == .failed || record.status == .pending {
        Button {
          Task { await store.resendRecord(record) }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help(state == .failed ? "Retry" : "Upload Now")
        .accessibilityLabel(state == .failed ? Text("Retry \(record.filename)") : Text("Upload Now \(record.filename)"))
      }
    }
    .help(record.status == .failed ? (record.lastError ?? "") : "")
  }
}

/// What else there is to know: the error, live speed, or where the file is.
private struct ActivityDetailCell: View {
  let store: MacSyncStore
  let record: TransferRecord
  @Environment(\.backgroundProminence) private var prominence

  var body: some View {
    Group {
      if record.status == .failed, let error = record.lastError, !error.isEmpty {
        Text(error)
          .foregroundStyle(prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
          .help(error)
      } else if record.status == .sending, let worker = store.activeWorker(for: record.id, filename: record.filename) {
        Text(liveDetail(worker))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      } else if record.wasAlreadyInLibrary {
        Text("Already in Google Photos")
          .foregroundStyle(.secondary)
      } else if let path = record.sourcePath {
        Text(abbreviatedHomePath((path as NSString).deletingLastPathComponent))
          .truncationMode(.middle)
          .foregroundStyle(.secondary)
          .help(abbreviatedHomePath(path))
      } else {
        Text(verbatim: "")
      }
    }
    .lineLimit(1)
  }

  private func liveDetail(_ worker: WorkerState) -> String {
    guard worker.status == "uploading", worker.bytesTotal > 0 else {
      return switch worker.status {
      case "hashing": String(localized: "Preparing…")
      case "checking": String(localized: "Checking Google Photos…")
      case "finalizing": String(localized: "Finishing…")
      default: String(localized: "Waiting…")
      }
    }
    let bytes = String(
      localized: "\(ByteFormat.string(worker.bytesUploaded)) of \(ByteFormat.string(worker.bytesTotal))")
    return ([bytes, worker.formattedSpeed, worker.formattedETA].filter { !$0.isEmpty }).joined(separator: " · ")
  }
}
