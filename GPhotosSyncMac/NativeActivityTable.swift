import AppKit
import GPhotosKit
import Observation
import SwiftUI

/// AppKit owns row reuse; SwiftUI owns the records, selection, and cell content.
struct NativeActivityTable: NSViewRepresentable {
  enum Column: String, CaseIterable {
    case name, status, size, date, details

    var title: String {
      switch self {
      case .name: String(localized: "Name")
      case .status: String(localized: "Status")
      case .size: String(localized: "Size")
      case .date: String(localized: "Date")
      case .details: String(localized: "Details")
      }
    }
  }

  final class Rows: Sendable {
    static let empty = Rows([])

    let records: [TransferRecord]
    let indexByID: [String: Int]

    init(_ records: [TransferRecord]) {
      self.records = records
      var indices: [String: Int] = [:]
      indices.reserveCapacity(records.count)
      for (index, record) in records.enumerated() { indices[record.id] = index }
      indexByID = indices
    }
  }

  let rows: Rows
  @Binding var selection: Set<String>
  let cell: (TransferRecord, Column) -> AnyView
  let sortChanged: ([NSSortDescriptor]) -> Void
  let menu: ([TransferRecord]) -> NSMenu
  let primaryAction: ([TransferRecord]) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeScrollView() }
  func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(self) }

  @MainActor
  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var parent: NativeActivityTable
    private var snapshot = Rows.empty
    var rows: [TransferRecord] { snapshot.records }
    private var updating = false
    private weak var table: TableView?

    init(_ parent: NativeActivityTable) { self.parent = parent }

    func makeScrollView() -> NSScrollView {
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true
      scroll.hasHorizontalScroller = true
      scroll.autohidesScrollers = true
      scroll.drawsBackground = false
      let table = TableView()
      table.delegate = self
      table.dataSource = self
      table.style = .inset
      table.usesAlternatingRowBackgroundColors = true
      table.usesAutomaticRowHeights = false
      table.rowSizeStyle = .custom
      table.rowHeight = 30
      table.allowsMultipleSelection = true
      table.allowsColumnReordering = true
      table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
      for column in Column.allCases {
        let native = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
        native.title = column.title
        switch column {
        case .name:
          native.minWidth = 180
          native.width = 280
        case .status:
          native.minWidth = 130
          native.width = 150
          native.maxWidth = 190
        case .size:
          native.minWidth = 64
          native.width = 80
          native.maxWidth = 110
        case .date:
          native.minWidth = 110
          native.width = 150
          native.maxWidth = 200
        case .details:
          native.minWidth = 120
          native.width = 260
        }
        if column != .details {
          native.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
        }
        table.addTableColumn(native)
      }
      table.frame.size.width = table.tableColumns.reduce(0) { $0 + $1.width }
      table.autoresizingMask = [.width]
      table.target = self
      table.doubleAction = #selector(openSelection)
      table.makeMenu = { [weak self] in
        guard let self else { return nil }
        return self.parent.menu(self.selectedRecords())
      }
      table.copySelection = { [weak self] in
        guard let self else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(self.selectedRecords().map(\.filename).joined(separator: "\n"), forType: .string)
      }
      scroll.documentView = table
      self.table = table
      update(parent)
      return scroll
    }

    func update(_ parent: NativeActivityTable) {
      self.parent = parent
      guard let table else { return }
      updating = true
      defer { updating = false }
      if snapshot !== parent.rows {
        snapshot = parent.rows
        // reloadData reuses only visible cells. Animated row diffs previously built
        // thousands of hosting views and raced SwiftUI's row generator on rapid filters.
        table.reloadData()
      }
      let selected = IndexSet(parent.selection.compactMap { snapshot.indexByID[$0] })
      if selected != table.selectedRowIndexes { table.selectRowIndexes(selected, byExtendingSelection: false) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
      guard rows.indices.contains(row), let identifier = tableColumn?.identifier,
        let column = Column(rawValue: identifier.rawValue)
      else { return nil }
      let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? HostingCell ?? HostingCell()
      view.identifier = identifier
      view.presentation.content = parent.cell(rows[row], column)
      return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
      guard !updating, let table else { return }
      let ids = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
      if ids != parent.selection { parent.selection = ids }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
      guard !updating else { return }
      parent.sortChanged(tableView.sortDescriptors)
    }

    private func selectedRecords() -> [TransferRecord] {
      table?.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil } ?? []
    }

    @objc private func openSelection() { parent.primaryAction(selectedRecords()) }
  }

  final class TableView: NSTableView {
    var makeMenu: (() -> NSMenu?)?
    var copySelection: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
      let row = row(at: convert(event.locationInWindow, from: nil))
      if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
      return makeMenu?()
    }

    @objc func copy(_ sender: Any?) { copySelection?() }
  }

  @MainActor
  @Observable
  final class CellPresentation {
    var content = AnyView(EmptyView())
    var isEmphasized = false
  }

  private struct CellContent: View {
    let presentation: CellPresentation

    var body: some View {
      presentation.content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .environment(\.backgroundProminence, presentation.isEmphasized ? .increased : .standard)
    }
  }

  final class HostingCell: NSTableCellView {
    let presentation = CellPresentation()

    override var backgroundStyle: NSView.BackgroundStyle {
      didSet {
        let isEmphasized = backgroundStyle == .emphasized
        if presentation.isEmphasized != isEmphasized { presentation.isEmphasized = isEmphasized }
      }
    }

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      let host = NSHostingView(rootView: CellContent(presentation: presentation))
      host.sizingOptions = []
      host.frame = bounds
      host.autoresizingMask = [.width, .height]
      addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  }
}
