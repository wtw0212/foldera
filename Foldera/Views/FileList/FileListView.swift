import AppKit
import SwiftUI

/// Details view of the current folder, backed by `NSTableView` for speed with large folders.
struct FileListView: NSViewRepresentable {
    let tab: BrowserTab
    let items: [FileItem]
    let selection: Set<URL>
    let sort: SortOrder
    let showExtensions: Bool
    let rowHeight: CGFloat
    let cutURLs: Set<URL>
    let renameRequest: BrowserTab.RenameRequest?
    let focusToken: Int
    let openInNewTab: (URL) -> Void

    private enum Column: String, CaseIterable {
        case name, dateModified, kind, size

        var field: SortField { SortField(rawValue: rawValue)! }

        var width: CGFloat {
            switch self {
            case .name: 320
            case .dateModified: 160
            case .kind: 150
            case .size: 100
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTableView()
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

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.headerCell = ExplorerHeaderCell(textCell: column.field.title)
            tableColumn.width = column.width
            tableColumn.minWidth = 60
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: column.rawValue,
                ascending: column == .name || column == .kind
            )
            table.addTableColumn(tableColumn)
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

        let tabChanged = coordinator.tabID != tab.id
        coordinator.tabID = tab.id
        if table.rowHeight != rowHeight { table.rowHeight = rowHeight }

        let presentation = Coordinator.Presentation(showExtensions: showExtensions, cutURLs: cutURLs)
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

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, FileTableCommands {
        struct Presentation: Equatable {
            var showExtensions = true
            var cutURLs: Set<URL> = []
        }

        var parent: FileListView?
        weak var table: FileTableView?
        var items: [FileItem] = []
        var presentation = Presentation()
        var tabID: UUID?
        var focusToken = -1
        var handledRename: UUID?

        private var isSyncing = false
        private var editing: (row: Int, url: URL, keepExtension: String?)?
        private var needsReloadAfterEdit = false
        private var renameCancelled = false

        private var tab: BrowserTab? { parent?.tab }

        func syncing(_ body: () -> Void) {
            isSyncing = true
            body()
            isSyncing = false
        }

        func reloadPreservingEdits() {
            if editing != nil {
                needsReloadAfterEdit = true
                return
            }
            syncing { table?.reloadData() }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            items[row].url as NSURL
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isSyncing, let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key, let field = SortField(rawValue: key) else { return }
            tab?.sort = SortOrder(field: field, ascending: descriptor.ascending)
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
                cell.label.stringValue = item.title(showExtensions: presentation.showExtensions)
                cell.label.delegate = self
                cell.setEditing(false)
                cell.alphaValue = alpha
                return cell
            }
            let cell = tableView.makeView(withIdentifier: TextCellView.identifier, owner: nil) as? TextCellView ?? TextCellView()
            switch column {
            case .dateModified: cell.label.stringValue = FileFormat.date(item.dateModified)
            case .kind: cell.label.stringValue = item.kind
            case .size: cell.label.stringValue = FileFormat.size(item.size)
            case .name: break
            }
            cell.label.alignment = column == .size ? .right : .left
            cell.alphaValue = alpha
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let table else { return }
            let urls = table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0].url : nil }
            tab?.selection = Set(urls)
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
            guard let table, row < items.count else { return }
            table.scrollRowToVisible(row)
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NameCellView else { return }
            let item = items[row]
            // With extensions hidden, only the stem is edited and the extension is kept, like Explorer.
            let ext = (item.name as NSString).pathExtension
            let keepExtension = !presentation.showExtensions && !item.isNavigable && !ext.isEmpty ? ext : nil
            editing = (row, item.url, keepExtension)
            renameCancelled = false
            cell.label.stringValue = keepExtension == nil ? item.name : (item.name as NSString).deletingPathExtension
            cell.setEditing(true)
            table.window?.makeFirstResponder(cell.label)
            if let editor = cell.label.currentEditor() {
                let stem = keepExtension == nil && !item.isNavigable && !ext.isEmpty
                    ? (item.name as NSString).deletingPathExtension
                    : cell.label.stringValue
                editor.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                renameCancelled = true
                control.abortEditing()
                finishEditing(control as? NSTextField)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            finishEditing(notification.object as? NSTextField)
        }

        private func finishEditing(_ field: NSTextField?) {
            guard let current = editing else { return }
            editing = nil
            let newName = (field?.stringValue ?? "") + (current.keepExtension.map { ".\($0)" } ?? "")
            (field?.superview as? NameCellView)?.setEditing(false)
            if renameCancelled || newName == current.url.lastPathComponent {
                tab?.renameRequest = nil
                syncing { table?.reloadData(forRowIndexes: IndexSet(integer: current.row), columnIndexes: IndexSet(integer: 0)) }
            } else {
                tab?.commitRename(of: current.url, to: newName)
            }
            if needsReloadAfterEdit {
                needsReloadAfterEdit = false
                syncing { table?.reloadData() }
            }
            table?.window?.makeFirstResponder(table)
        }

        // MARK: FileTableCommands

        func openSelection() { tab?.openSelection() }
        func beginRename() { tab?.beginRename() }
        func goUp() { tab?.goUp() }
        func goBack() { tab?.goBack() }
        func trashSelection() { tab?.trashSelection() }
        func cutSelection() { tab?.cutSelection() }
        func copySelection() { tab?.copySelection() }
        func paste() { tab?.paste() }
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
