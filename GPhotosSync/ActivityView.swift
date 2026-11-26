import GPhotosKit
import SwiftUI

struct ActivityView: View {
  let model: AppModel
  @State private var filter: ActivityFilter
  @State private var query = ""
  @State private var rows: AccountActivityRows?

  private var request: ActivityRequest {
    ActivityRequest(
      email: model.selectedAccount?.email, revision: model.accountBucketsRevision, filter: filter, query: query)
  }

  init(model: AppModel, filter: ActivityFilter) {
    self.model = model
    // Seeds the initial selection; the filter bar owns it afterwards.
    _filter = State(initialValue: filter)
  }

  var body: some View {
    let visible = rows?.records(for: model.selectedAccount?.email) ?? []
    let request = self.request
    return List {
      ForEach(visible) { record in
        LiveActivityRow(model: model, record: record)
          .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if record.status == .failed {
              Button("Skip Future Uploads", systemImage: "forward.end") {
                Task { await model.skipFailedRecords([record.id]) }
              }
            }
            if record.status == .failed || record.status == .pending {
              Button(
                record.status == .failed ? "Retry" : "Upload Now",
                systemImage: record.status == .failed ? "arrow.clockwise" : "icloud.and.arrow.up"
              ) {
                Task { await model.resendRecord(record) }
              }
              .tint(.blue)
            }
          }
          .listRowBackground(Rectangle().fill(.regularMaterial))
          .contextMenu {
            Button("Copy File Name", systemImage: "doc.on.doc") {
              copy(record.filename, from: record)
            }
            if let path = record.sourcePath {
              Button("Copy Path", systemImage: "link") {
                copy(path, from: record)
              }
            }
            if record.status == .failed || record.status == .pending {
              Button(
                record.status == .failed ? "Retry" : "Upload Now",
                systemImage: record.status == .failed ? "arrow.clockwise" : "icloud.and.arrow.up"
              ) {
                Task { await model.resendRecord(record) }
              }
            }
            if record.status == .failed, let error = record.lastError, !error.isEmpty {
              Button("Copy Error", systemImage: "exclamationmark.bubble") {
                copy(error, from: record)
              }
            }
            if record.status == .failed {
              Button("Skip Future Uploads", systemImage: "forward.end") {
                Task { await model.skipFailedRecords([record.id]) }
              }
            }
          }
      }
    }
    .scrollContentBackground(.hidden)
    .background { AmbientBackground(tint: .accentColor) }
    .overlay {
      if visible.isEmpty {
        if query.isEmpty {
          ContentUnavailableView(
            filter.emptyTitle, systemImage: filter.emptySymbol, description: Text(filter.emptyDescription))
        } else {
          ContentUnavailableView.search(text: query)
        }
      }
    }
    .scrollDismissesKeyboard(.interactively)
    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search activity")
    .navigationTitle("Activity")
    .toolbarTitleDisplayMode(.inline)
    .safeAreaBar(edge: .top) {
      ActivityFilterBar(selection: $filter, counts: model.accountBuckets.activityCounts)
    }
    .toolbar {
      if model.accountFailedCount > 0 {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Retry All") { Task { await model.retryFailedForUser() } }
            .disabled(model.isRunning)
        }
      }
    }
    .task(id: request) {
      if !request.query.isEmpty {
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      }
      let buckets = model.accountBuckets
      guard buckets.accountEmail == request.email else { return }
      let matches = await Task.detached(priority: .userInitiated) {
        buckets.activityRows(filter: request.filter, query: request.query)
      }.value
      guard !Task.isCancelled, request == self.request else { return }
      rows = matches
    }
  }

  private func copy(_ text: String, from record: TransferRecord) {
    guard let email = model.selectedAccount?.email, email == TransferRecord.accountEmail(fromScopedID: record.id) else { return }
    UIPasteboard.general.string = text
  }

  private struct ActivityRequest: Equatable, Sendable {
    let email: String?
    let revision: Int
    let filter: ActivityFilter
    let query: String
  }
}

/// Reads its own worker, so per-tick progress re-renders this row rather than the list.
/// Only sending rows read it; the rest never observe the worker pool.
private struct LiveActivityRow: View {
  let model: AppModel
  let record: TransferRecord

  var body: some View {
    ActivityRow(
      record: record,
      worker: record.status == .sending ? model.workerPool.workers.first { $0.itemID == record.id } : nil,
      waitingReason: model.waitingReason(for: record),
      onRetry: { Task { await model.resendRecord(record) } }
    )
  }
}
