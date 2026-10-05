import AppKit
import SwiftUI

/// Details view of the current folder, backed by `NSTableView` for speed with large folders.
struct FileListView: NSViewRepresentable {
    @Environment(\.locale) private var locale
    let tab: BrowserTab
    let items: [FileItem]
    let selection: Set<URL>
    let sort: SortOrder
    let showExtensions: Bool
    let rowHeight: CGFloat
    let cutURLs: Set<URL>
    let renameRequest: BrowserTab.RenameRequest?
    let focusToken: Int
    /// Showing recursive search results: adds the "Folder" column.
    let isSearchResults: Bool
    let openInNewTab: (URL) -> Void
    let openInBackgroundTab: (URL) -> Void
    var onFocus: () -> Void = {}

    private enum Column: String, CaseIterable {
        case name, location, dateModified, kind, size

        var field: SortField? { SortField(rawValue: rawValue) }

        var title: String { field?.title ?? L10n.text("Folder") }

        var width: CGFloat {
            switch self {
            case .name: 320
            case .dateModified: 160
            case .kind: 150
            case .size: 100
            case .location: 280
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private static func makeColumn(_ column: Column) -> NSTableColumn {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
        tableColumn.headerCell = ExplorerHeaderCell(textCell: column.title)
        tableColumn.width = column.width
        tableColumn.minWidth = 60
        if column.field != nil {
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: column.rawValue,
                ascending: column == .name || column == .kind
            )
        }
        return tableColumn
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTableView()
        table.setAccessibilityIdentifier("file-list")
        table.commands = context.coordinator
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.style = .plain
        table.headerView = ExplorerHeaderView()
        table.headerView?.frame.size.height = 30
        table.cornerView = nil
        table.backgroundColor = Theme.content
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.focusRingType = .none
        table.rowHeight = rowHeight
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.registerForDraggedTypes(ItemPasteboard.types)

        for column in Column.allCases where column != .location {
            table.addTableColumn(Self.makeColumn(column))
        }
        table.autosaveName = "FileList"
        table.autosaveTableColumns = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.content
        scroll.borderType = .noBorder

        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        table.onFocus = onFocus

        let tabChanged = coordinator.tabID != tab.id
        coordinator.tabID = tab.id
        if table.rowHeight != rowHeight { table.rowHeight = rowHeight }
        // The "Folder" column only exists while showing search results.
        let locationID = NSUserInterfaceItemIdentifier(Column.location.rawValue)
        let locationColumn = table.tableColumn(withIdentifier: locationID)
        if isSearchResults, locationColumn == nil {
            table.addTableColumn(Self.makeColumn(.location))
            table.moveColumn(table.numberOfColumns - 1, toColumn: min(1, table.numberOfColumns - 1))
        } else if !isSearchResults, let locationColumn {
            table.removeTableColumn(locationColumn)
        }
        for column in table.tableColumns {
            if let field = Column(rawValue: column.identifier.rawValue) {
                column.title = field.title
            }
        }
        table.headerView?.needsDisplay = true

        let presentation = Coordinator.Presentation(showExtensions: showExtensions, cutURLs: cutURLs, localeIdentifier: locale.identifier)
        if tabChanged || coordinator.items != items || coordinator.presentation != presentation {
            coordinator.items = items
            coordinator.presentation = presentation
            coordinator.reloadPreservingEdits()
            if tabChanged { table.scroll(.zero) }
        }

        coordinator.syncing {
            let descriptor = NSSortDescriptor(key: sort.field.rawValue, ascending: sort.ascending)
            if table.sortDescriptors.first != descriptor {
                table.sortDescriptors = [descriptor]
                table.headerView?.needsDisplay = true
            }
            let rows = IndexSet(items.indices.filter { selection.contains(items[$0].url) })
            if table.selectedRowIndexes != rows {
                table.selectRowIndexes(rows, byExtendingSelection: false)
                if let first = rows.first { table.scrollRowToVisible(first) }
            }
        }

        if coordinator.focusToken != focusToken || tabChanged {
            coordinator.focusToken = focusToken
            DispatchQueue.main.async { table.window?.makeFirstResponder(table) }
        }

        if let request = renameRequest, request.id != coordinator.handledRename {
            if let row = items.firstIndex(where: { $0.url == request.url }) {
                coordinator.handledRename = request.id
                DispatchQueue.main.async { coordinator.beginEditing(row: row) }
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, FileViewCommands {
        struct Presentation: Equatable {
            var showExtensions = true
            var cutURLs: Set<URL> = []
            var localeIdentifier = ""
        }

        var parent: FileListView?
        weak var table: FileTableView?
        var items: [FileItem] = []
        var presentation = Presentation()
        var tabID: UUID?
        var focusToken = -1
        var handledRename: UUID?

        private var isSyncing = false
        private let renamer = InlineRenamer()

        override init() {
            super.init()
            renamer.onFinish = { [weak self] in
                guard let self, let table = self.table else { return }
                self.syncing { table.reloadData() }
                table.window?.makeFirstResponder(table)
            }
        }

        private var tab: BrowserTab? { parent?.tab }

        func syncing(_ body: () -> Void) {
            isSyncing = true
            body()
            isSyncing = false
        }

        func reloadPreservingEdits() {
            guard !renamer.isEditing else { return }
            syncing { table?.reloadData() }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            ItemPasteboard.writer(for: items[row].url)
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isSyncing, let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key, let field = SortField(rawValue: key) else { return }
            tab?.sort = SortOrder(field: field, ascending: descriptor.ascending)
        }

        // MARK: Drop

        /// Dropping on a folder row targets that folder; anywhere else targets the current folder.
        private func dropTarget(row: Int, operation: NSTableView.DropOperation) -> URL? {
            if operation == .on, row >= 0, row < items.count, items[row].isNavigable { return items[row].url }
            return tab?.url
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: any NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation operation: NSTableView.DropOperation
        ) -> NSDragOperation {
            let urls = FileDrop.fileURLs(from: info.draggingPasteboard)
            guard let target = dropTarget(row: row, operation: operation) else { return [] }
            if target == tab?.url {
                tableView.setDropRow(-1, dropOperation: .on) // highlight the whole list
            }
            return FileDrop.dragOperation(for: urls, into: target)
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: any NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard let target = dropTarget(row: row, operation: dropOperation) else { return false }
            return FileDrop.perform(FileDrop.fileURLs(from: info.draggingPasteboard), into: target)
        }

        // MARK: Delegate

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            FileRowView()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let item = items[row]
            let alpha: CGFloat = presentation.cutURLs.contains(item.url) && FileClipboard.shared.isCut(item.url) ? 0.5 : 1
            if column == .name {
                let cell = tableView.makeView(withIdentifier: NameCellView.identifier, owner: nil) as? NameCellView ?? NameCellView()
                cell.iconView.image = FileIcons.icon(for: item)
                // Hidden items (shown with "Hidden items" on) get a faded icon and gray name, like Explorer.
                cell.iconView.alphaValue = item.isHidden ? 0.45 : 1
                cell.label.textColor = item.isHidden ? Theme.tertiaryText : Theme.text
                cell.label.stringValue = item.title(showExtensions: presentation.showExtensions)
                cell.setEditing(false)
                cell.alphaValue = alpha
                return cell
            }
            let cell = tableView.makeView(withIdentifier: TextCellView.identifier, owner: nil) as? TextCellView ?? TextCellView()
            switch column {
            case .dateModified: cell.label.stringValue = FileFormat.date(item.dateModified)
            case .kind: cell.label.stringValue = item.localizedKind
            case .size: cell.label.stringValue = FileFormat.size(item.size)
            case .location: cell.label.stringValue = FileFormat.location(of: item.url)
            case .name: break
            }
            cell.label.alignment = column == .size ? .right : .left
            cell.label.lineBreakMode = column == .location ? .byTruncatingHead : .byTruncatingTail
            cell.alphaValue = alpha
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let table else { return }
            let urls = table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0].url : nil }
            tab?.selection = Set(urls)
            QuickLook.shared.selectionChanged()
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            tableColumn?.identifier.rawValue == Column.name.rawValue
                ? items[row].title(showExtensions: presentation.showExtensions)
                : nil
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < items.count else { return }
            tab?.open(items[row])
        }

        // MARK: Inline rename

        func beginEditing(row: Int) {
            guard let table, let tab, row < items.count else { return }
            table.scrollRowToVisible(row)
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NameCellView else { return }
            renamer.begin(field: cell.label, item: items[row], showExtensions: presentation.showExtensions, tab: tab) { editing in
                cell.setEditing(editing)
            }
        }

        // MARK: FileViewCommands

        func openSelection() { tab?.openSelection() }
        func beginRename() { tab?.beginRename() }
        func goUp() { tab?.goUp() }
        func goBack() { tab?.goBack() }
        func trashSelection() { tab?.trashSelection() }
        func cutSelection() { tab?.cutSelection() }
        func copySelection() { tab?.copySelection() }
        func paste() { tab?.paste() }
        func zoom(in zoomIn: Bool) { tab?.zoom(in: zoomIn) }
        func openInBackgroundTab(index: Int) {
            guard index < items.count, items[index].isNavigable else { return }
            parent?.openInBackgroundTab(items[index].url)
        }
        func toggleQuickLook() {
            QuickLook.shared.toggle { [weak self] in self?.tab?.selectedItems.map(\.url) ?? [] }
        }
        var hasSelection: Bool { !(table?.selectedRowIndexes.isEmpty ?? true) }
        var canPaste: Bool { tab?.canPaste ?? false }

        func contextMenu(forRow row: Int) -> NSMenu? {
            guard let tab, let parent else { return nil }
            // Selection may have just changed from the right-click; push it to the tab first.
            if let table {
                tab.selection = Set(table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0].url : nil })
            }
            return row >= 0
                ? ContextMenus.itemMenu(tab: tab, openInNewTab: parent.openInNewTab)
                : ContextMenus.backgroundMenu(tab: tab)
        }
    }
}
