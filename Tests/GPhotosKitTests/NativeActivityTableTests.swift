#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import GPhotosKit

  @Suite("Native Activity table")
  @MainActor
  struct NativeActivityTableTests {
    private final class State {
      var selection = Set<String>()
      var cells = 0
      var sortDescriptors: [NSSortDescriptor] = []
      var menuIDs: [String] = []
    }

    private func view(_ rows: [TransferRecord], revision: Int, state: State) -> NativeActivityTable {
      NativeActivityTable(
        rows: rows, revision: revision,
        selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
        cell: { record, _ in
          state.cells += 1
          return AnyView(Text(record.filename))
        },
        sortChanged: { state.sortDescriptors = $0 },
        menu: { records in
          state.menuIDs = records.map(\.id)
          return NSMenu()
        }, primaryAction: { _ in })
    }

    @Test("Rapid full, failed, and empty reloads keep one fixed-height table and reject stale row requests")
    func rapidScopeChanges() async {
      let records = (0..<12_600).map {
        TransferRecord(id: "r\($0)", filename: "photo-\($0).jpg", mediaType: "Photo", status: $0 < 7 ? .failed : .sent)
      }
      let state = State()
      let initial = view(records, revision: 0, state: state)
      let coordinator = initial.makeCoordinator()
      let scroll = coordinator.makeScrollView()
      scroll.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
      let table = scroll.documentView as! NSTableView
      #expect(!table.usesAutomaticRowHeights)
      #expect(table.rowHeight == 30)
      #expect(table.numberOfRows == records.count)
      for revision in 1...1000 {
        if revision.isMultiple(of: 25) { await Task.yield() }
        let rows = revision.isMultiple(of: 3) ? [] : revision.isMultiple(of: 2) ? records : Array(records.prefix(7))
        coordinator.update(view(rows, revision: revision, state: state))
        #expect(table === scroll.documentView)
        #expect(table.numberOfRows == rows.count)
        #expect(coordinator.tableView(table, viewFor: table.tableColumns[0], row: rows.count) == nil)
        #expect(coordinator.tableView(table, viewFor: table.tableColumns[0], row: -1) == nil)
        if !rows.isEmpty {
          #expect(coordinator.tableView(table, viewFor: table.tableColumns[0], row: 0) != nil)
        }
      }
      // Reloading must not eagerly construct all 12,600 rows' cell views.
      #expect(state.cells < 2000)
    }

    @Test("Selection follows record IDs when rows are reordered or removed")
    func selectionUsesIDs() {
      let state = State()
      state.selection = ["a"]
      let a = TransferRecord(id: "a", filename: "a.jpg", mediaType: "Photo", status: .sent)
      let b = TransferRecord(id: "b", filename: "b.jpg", mediaType: "Photo", status: .failed)
      let initial = view([a, b], revision: 0, state: state)
      let coordinator = initial.makeCoordinator()
      let scroll = coordinator.makeScrollView()
      let table = scroll.documentView as! NSTableView
      #expect(table.selectedRowIndexes == IndexSet(integer: 0))
      coordinator.update(view([b, a], revision: 1, state: state))
      #expect(table.selectedRowIndexes == IndexSet(integer: 1))
      coordinator.update(view([b], revision: 2, state: state))
      #expect(table.selectedRowIndexes.isEmpty)
      #expect(state.selection == ["a"])
    }

    @Test("Native sort and context-menu callbacks use the current rows and selection")
    func nativeCallbacks() {
      let state = State()
      let a = TransferRecord(id: "a", filename: "a.jpg", mediaType: "Photo", status: .sent)
      let b = TransferRecord(id: "b", filename: "b.jpg", mediaType: "Photo", status: .failed)
      let coordinator = view([a, b], revision: 0, state: state).makeCoordinator()
      let scroll = coordinator.makeScrollView()
      let table = scroll.documentView as! NativeActivityTable.TableView
      table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
      #expect(state.sortDescriptors.first?.key == "name")
      #expect(state.sortDescriptors.first?.ascending == false)
      table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
      #expect(state.selection == ["b"])
      #expect(table.makeMenu?() != nil)
      #expect(state.menuIDs == ["b"])
      coordinator.update(view([a], revision: 1, state: state))
      #expect(table.makeMenu?() != nil)
      #expect(state.menuIDs.isEmpty)
    }

    @Test("SwiftUI updates a background window without replacing the native table or losing row counts")
    func swiftUIReloadsInBackgroundWindow() async {
      _ = NSApplication.shared
      let state = State()
      let records = (0..<12_600).map {
        TransferRecord(id: "r\($0)", filename: "photo-\($0).jpg", mediaType: "Photo", status: $0 < 7 ? .failed : .sent)
      }
      let host = NSHostingView(rootView: view(records, revision: 0, state: state))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      defer { window.close() }
      host.layoutSubtreeIfNeeded()

      func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { findTable($0) }.first
      }
      guard let original = findTable(host) else {
        Issue.record("SwiftUI did not create the native Activity table")
        return
      }
      for revision in 1...300 {
        let rows = revision.isMultiple(of: 3) ? [] : revision.isMultiple(of: 2) ? records : Array(records.prefix(7))
        host.rootView = view(rows, revision: revision, state: state)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(2))
        host.layoutSubtreeIfNeeded()
        #expect(findTable(host) === original)
        #expect(original.numberOfRows == rows.count)
        #expect(!original.usesAutomaticRowHeights)
        if !rows.isEmpty {
          #expect(original.view(atColumn: 0, row: 0, makeIfNecessary: true) != nil)
        }
      }
      #expect(!window.isVisible)
    }
  }
#endif
