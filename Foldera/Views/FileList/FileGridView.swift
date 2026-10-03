import AppKit
import SwiftUI

/// Icon, List, Tiles and Content layouts, backed by `NSCollectionView`.
struct FileGridView: NSViewRepresentable {
    @Environment(\.locale) private var locale
    let tab: BrowserTab
    let mode: ViewMode
    let items: [FileItem]
    let selection: Set<URL>
    let showExtensions: Bool
    let cutURLs: Set<URL>
    let renameRequest: BrowserTab.RenameRequest?
    let focusToken: Int
    let openInNewTab: (URL) -> Void
    let openInBackgroundTab: (URL) -> Void
    var onFocus: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let layout = FileGridLayout()
        layout.mode = mode
        let grid = FileCollectionView()
        grid.collectionViewLayout = layout
        grid.dataSource = coordinator
        grid.delegate = coordinator
        grid.commands = coordinator
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.allowsEmptySelection = true
        grid.backgroundColors = [Theme.content]
        grid.register(FileGridItem.self, forItemWithIdentifier: FileGridItem.identifier)
        grid.registerForDraggedTypes(ItemPasteboard.types)
        grid.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        grid.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        grid.onDoubleClick = { [weak coordinator] indexPath in coordinator?.open(at: indexPath.item) }

        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.content
        coordinator.grid = grid
        coordinator.layout = layout
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let grid = coordinator.grid else { return }
        grid.onFocus = onFocus

        let tabChanged = coordinator.tabID != tab.id
        coordinator.tabID = tab.id
        let presentation = Coordinator.Presentation(mode: mode, showExtensions: showExtensions, cutURLs: cutURLs, localeIdentifier: locale.identifier)
        if tabChanged || coordinator.items != items || coordinator.presentation != presentation {
            let modeChanged = coordinator.presentation.mode != mode
            coordinator.items = items
            coordinator.presentation = presentation
            coordinator.layout?.mode = mode
            coordinator.reloadPreservingEdits()
            if tabChanged || modeChanged { grid.scroll(.zero) }
        }

        let paths = Set(items.indices.filter { selection.contains(items[$0].url) }.map { IndexPath(item: $0, section: 0) })
        // Changing the selection mid-click makes the collection view's mouse session undo the click.
        if grid.selectionIndexPaths != paths, NSEvent.pressedMouseButtons == 0 {
            coordinator.syncing {
                grid.selectionIndexPaths = paths
                if let first = paths.min() { grid.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge) }
            }
        }

        if coordinator.focusToken != focusToken || tabChanged {
            coordinator.focusToken = focusToken
            DispatchQueue.main.async { grid.window?.makeFirstResponder(grid) }
        }

        if let request = renameRequest, request.id != coordinator.handledRename,
           let index = items.firstIndex(where: { $0.url == request.url }) {
            coordinator.handledRename = request.id
            DispatchQueue.main.async { coordinator.beginEditing(at: index) }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, FileViewCommands {
        struct Presentation: Equatable {
            var mode: ViewMode = .largeIcons
            var showExtensions = true
            var cutURLs: Set<URL> = []
            var localeIdentifier = ""
        }

        var parent: FileGridView?
        weak var grid: FileCollectionView?
        weak var layout: FileGridLayout?
        var items: [FileItem] = []
        var presentation = Presentation()
        var tabID: UUID?
        var focusToken = -1
        var handledRename: UUID?

        private var isSyncing = false
        private let renamer = InlineRenamer()
        private var needsReloadAfterEdit = false

        private var tab: BrowserTab? { parent?.tab }

        override init() {
            super.init()
            renamer.onFinish = { [weak self] in
                guard let self, let grid = self.grid else { return }
                self.needsReloadAfterEdit = false
                self.reloadKeepingSelection()
                grid.window?.makeFirstResponder(grid)
            }
        }

        func syncing(_ body: () -> Void) {
            isSyncing = true
            body()
            isSyncing = false
        }

        func reloadPreservingEdits() {
            if renamer.isEditing {
                needsReloadAfterEdit = true
                return
            }
            reloadKeepingSelection()
        }

        /// `reloadData` drops the collection view's selection; put the tab's selection back.
        private func reloadKeepingSelection() {
            guard let grid else { return }
            let selected = tab?.selection ?? []
            syncing {
                grid.reloadData()
                grid.selectionIndexPaths = Set(items.indices.filter { selected.contains(items[$0].url) }.map { IndexPath(item: $0, section: 0) })
            }
        }

        func open(at index: Int) {
            guard index < items.count else { return }
            tab?.open(items[index])
        }

        // MARK: Data source

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            items.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let view = collectionView.makeItem(withIdentifier: FileGridItem.identifier, for: indexPath)
            guard let gridItem = view as? FileGridItem else { return view }
            let item = items[indexPath.item]
            let mode = presentation.mode
            gridItem.representedURL = item.url
            gridItem.cell.configure(
                item: item,
                mode: mode,
                showExtensions: presentation.showExtensions,
                dimmed: presentation.cutURLs.contains(item.url) && FileClipboard.shared.isCut(item.url)
            )
            gridItem.cell.iconView.image = Thumbnails.shared.cached(for: item, size: mode.iconSize) ?? FileIcons.icon(for: item)
            if mode.showsThumbnails {
                let scale = collectionView.window?.backingScaleFactor ?? 2
                Task { [weak gridItem] in
                    guard let image = await Thumbnails.shared.load(for: item, size: mode.iconSize, scale: scale),
                          let gridItem, gridItem.representedURL == item.url else { return }
                    gridItem.cell.iconView.image = image
                }
            }
            return gridItem
        }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
            ItemPasteboard.writer(for: items[indexPath.item].url)
        }

        // MARK: Selection

        private func pushSelection() {
            guard !isSyncing, let grid else { return }
            tab?.selection = Set(grid.selectionIndexPaths.compactMap { $0.item < items.count ? items[$0.item].url : nil })
            QuickLook.shared.selectionChanged()
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { pushSelection() }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { pushSelection() }

        // MARK: Drop

        private func dropTarget(_ indexPath: IndexPath, _ operation: NSCollectionView.DropOperation) -> URL? {
            if operation == .on, indexPath.item < items.count, items[indexPath.item].isNavigable { return items[indexPath.item].url }
            return tab?.url
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            validateDrop draggingInfo: any NSDraggingInfo,
            proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
            dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
        ) -> NSDragOperation {
            guard let target = dropTarget(proposedIndexPath.pointee as IndexPath, dropOperation.pointee) else { return [] }
            if target == tab?.url { dropOperation.pointee = .before }
            return FileDrop.dragOperation(for: FileDrop.fileURLs(from: draggingInfo.draggingPasteboard), into: target)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            acceptDrop draggingInfo: any NSDraggingInfo,
            indexPath: IndexPath,
            dropOperation: NSCollectionView.DropOperation
        ) -> Bool {
            guard let target = dropTarget(indexPath, dropOperation) else { return false }
            return FileDrop.perform(FileDrop.fileURLs(from: draggingInfo.draggingPasteboard), into: target)
        }

        // MARK: Inline rename

        func beginEditing(at index: Int) {
            guard let grid, let tab, index < items.count else { return }
            let indexPath = IndexPath(item: index, section: 0)
            grid.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
            grid.layoutSubtreeIfNeeded()
            guard let gridItem = grid.item(at: indexPath) as? FileGridItem else { return }
            let cell = gridItem.cell
            renamer.begin(field: cell.nameLabel, item: items[index], showExtensions: presentation.showExtensions, tab: tab) { editing in
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
        var hasSelection: Bool { !(grid?.selectionIndexPaths.isEmpty ?? true) }
        var canPaste: Bool { tab?.canPaste ?? false }

        func contextMenu(forRow row: Int) -> NSMenu? {
            guard let tab, let parent else { return nil }
            pushSelection()
            return row >= 0
                ? ContextMenus.itemMenu(tab: tab, openInNewTab: parent.openInNewTab)
                : ContextMenus.backgroundMenu(tab: tab)
        }
    }
}
