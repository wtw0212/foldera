import AppKit
import SwiftUI
import Testing
@testable import Foldera

@MainActor
private final class TestHost<Content: View> {
    let view: NSHostingView<Content>
    let window: NSWindow

    init(_ content: Content) {
        view = NSHostingView(rootView: content)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
    }

    isolated deinit { window.close() }

    func descendants<T: NSView>(_ type: T.Type) -> [T] {
        func collect(_ view: NSView) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap(collect)
        }
        return collect(view)
    }
}

@Suite(.serialized)
@MainActor
struct HostedViewTests {
    private func grid(_ tab: BrowserTab, mode: ViewMode, background: @escaping (URL) -> Void = { _ in }) -> FileGridView {
        FileGridView(tab: tab, mode: mode, items: tab.visibleItems, selection: tab.selection,
            showExtensions: true, cutURLs: [], renameRequest: tab.renameRequest, focusToken: tab.focusListToken,
            openInNewTab: { _ in }, openInBackgroundTab: background)
    }

    private func list(_ tab: BrowserTab, search: Bool = false) -> FileListView {
        FileListView(tab: tab, items: tab.visibleItems, selection: tab.selection, sort: tab.sort,
            showExtensions: true, rowHeight: 30, cutURLs: [], renameRequest: tab.renameRequest,
            focusToken: tab.focusListToken, isSearchResults: search, openInNewTab: { _ in }, openInBackgroundTab: { _ in })
    }

    @Test func iconViewsCreateItemsSyncSelectionAndNavigateFolders() async throws {
        let directory = try TestDirectory()
        let folder = try directory.folder("nested"), text = try directory.file("note.txt")
        let tab = BrowserTab(url: directory.url)
        try await eventually { !tab.isLoading }
        var background: URL?
        let host = TestHost(grid(tab, mode: .largeIcons) { background = $0 })
        try await eventually { host.descendants(FileCollectionView.self).first?.numberOfItems(inSection: 0) == 2 }
        let collection = try #require(host.descendants(FileCollectionView.self).first)
        let coordinator = try #require(collection.delegate as? FileGridView.Coordinator)
        #expect(coordinator.collectionView(collection, numberOfItemsInSection: 0) == 2)
        let index = try #require(coordinator.items.firstIndex { $0.url == text })
        collection.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        coordinator.collectionView(collection, didSelectItemsAt: collection.selectionIndexPaths)
        #expect(tab.selection == [text] && coordinator.hasSelection)
        #expect(coordinator.collectionView(collection, pasteboardWriterForItemAt: IndexPath(item: index, section: 0)) as? NSURL == text as NSURL)
        for mode in ViewMode.allCases where mode != .details {
            host.view.rootView = grid(tab, mode: mode) { background = $0 }
            host.view.layoutSubtreeIfNeeded()
            try await eventually { coordinator.presentation.mode == mode }
            #expect(collection.selectionIndexPaths == [IndexPath(item: index, section: 0)])
        }
        let folderIndex = try #require(coordinator.items.firstIndex { $0.url == folder })
        coordinator.openInBackgroundTab(index: folderIndex)
        #expect(background == folder)
        #expect(coordinator.contextMenu(forRow: -1) != nil && coordinator.contextMenu(forRow: index) != nil)
        coordinator.open(at: coordinator.items.count)
        #expect(tab.url == directory.url)
        coordinator.open(at: folderIndex)
        #expect(tab.url == folder)
        collection.selectionIndexPaths = []
        coordinator.collectionView(collection, didDeselectItemsAt: [])
        #expect(tab.selection.isEmpty)
    }

    @Test func detailsViewAddsAndRemovesSearchColumnAndSynchronizesSort() async throws {
        let directory = try TestDirectory()
        try directory.file("note.txt"); try directory.folder("nested")
        let tab = BrowserTab(url: directory.url)
        try await eventually { !tab.isLoading }
        let host = TestHost(list(tab))
        try await eventually { host.descendants(FileTableView.self).first?.numberOfRows == 2 }
        let table = try #require(host.descendants(FileTableView.self).first)
        let coordinator = try #require(table.delegate as? FileListView.Coordinator)
        #expect(table.numberOfColumns == 4 && coordinator.numberOfRows(in: table) == 2)
        table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        coordinator.tableView(table, sortDescriptorsDidChange: [])
        #expect(tab.sort.field == .size && !tab.sort.ascending)
        table.selectRowIndexes([1], byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        #expect(tab.selection == [coordinator.items[1].url])
        host.view.rootView = list(tab, search: true)
        host.view.layoutSubtreeIfNeeded()
        try await eventually { table.numberOfColumns == 5 }
        for column in table.tableColumns {
            #expect(coordinator.tableView(table, viewFor: column, row: 1) != nil)
            #expect((coordinator.tableView(table, typeSelectStringFor: column, row: 1) != nil) == (column.identifier.rawValue == "name"))
        }
        #expect(coordinator.tableView(table, viewFor: NSTableColumn(identifier: .init("unknown")), row: 0) == nil)
        #expect(coordinator.tableView(table, viewFor: nil, row: 0) == nil)
        #expect(coordinator.tableView(table, pasteboardWriterForRow: 1) as? NSURL == coordinator.items[1].url as NSURL)
        #expect(coordinator.contextMenu(forRow: 1) != nil && coordinator.contextMenu(forRow: -1) != nil)
        host.view.rootView = list(tab)
        host.view.layoutSubtreeIfNeeded()
        try await eventually { table.numberOfColumns == 4 }
        #expect(table.rowInColumns(at: NSPoint(x: table.columnsMaxX + 1, y: 10)) == -1)
    }

    @Test func explorerSwitchesBetweenDetailsIconsDualPaneAndDrives() async throws {
        let directory = try TestDirectory(), preferences = try TestPreferences()
        let settings = AppSettings(defaults: preferences.defaults)
        settings.showNavigationPane = true
        settings.sidePane = .details
        let model = ExplorerWindowModel(settings: settings)
        model.primaryTab.navigate(to: directory.url)
        model.primaryTab.viewMode = .details
        try await eventually { !model.primaryTab.isLoading }
        let host = TestHost(ExplorerWindow(model: model, settings: settings))
        try await eventually { !host.descendants(FileTableView.self).isEmpty }
        model.primaryTab.viewMode = .tiles
        try await eventually { !host.descendants(FileCollectionView.self).isEmpty }
        model.toggleDualPane()
        try await eventually { host.descendants(NSSplitView.self).count >= 2 }
        model.focusedPane = .secondary
        model.activeTab.navigate(to: BrowserTab.thisMacURL)
        #expect(model.activeTab.isThisMac)
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.view.fittingSize.width > 0 && VolumeMonitor.shared.volumes.count > 0)
        model.toggleDualPane()
        model.primaryTab.navigate(to: directory.path("missing"))
        try await eventually { model.primaryTab.loadError != nil }
        #expect(host.view.fittingSize.height > 0)
    }

    @Test func swipeOverlayDrawsDirectionAndProgressAndClearsAfterAFlash() async throws {
        let feedback = SwipeFeedback()
        let host = TestHost(SwipeArrowOverlay(feedback: feedback))
        func pixels() throws -> Data {
            host.view.layoutSubtreeIfNeeded()
            let image = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: image)
            return try #require(image.tiffRepresentation)
        }
        let idle = try pixels()
        feedback.update(.back, progress: 0.1)
        try await Task.sleep(for: .milliseconds(100))
        let partial = try pixels()
        #expect(partial != idle && !feedback.isArmed)
        feedback.update(.forward, progress: 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try pixels() != partial && feedback.isArmed)
        feedback.flash(.back)
        try await eventually { !feedback.isActive }
        #expect(feedback.progress == 0)
    }

    @Test func dualPaneSwipeArrowAppearsOnlyInTheActivePane() async throws {
        let directory = try TestDirectory(), preferences = try TestPreferences()
        let settings = AppSettings(defaults: preferences.defaults)
        settings.showNavigationPane = false
        let model = ExplorerWindowModel(url: directory.url, settings: settings), swipe = SwipeFeedback()
        model.toggleDualPane()
        model.focusedPane = .secondary
        let host = TestHost(ExplorerWindow(model: model, settings: settings, swipe: swipe))
        try await eventually { host.descendants(NSSplitView.self).count >= 2 }
        try await Task.sleep(for: .milliseconds(200))
        func halves() throws -> (left: Data, right: Data) {
            host.view.layoutSubtreeIfNeeded()
            let bounds = host.view.bounds
            func capture(_ rect: NSRect) throws -> Data {
                let image = try #require(host.view.bitmapImageRepForCachingDisplay(in: rect))
                host.view.cacheDisplay(in: rect, to: image)
                return try #require(image.tiffRepresentation)
            }
            return (try capture(NSRect(x: 0, y: 0, width: bounds.midX - 2, height: bounds.height)),
                    try capture(NSRect(x: bounds.midX + 2, y: 0, width: bounds.midX - 2, height: bounds.height)))
        }
        let idle = try halves()
        // Back draws at the pane's left edge; across the whole window it would land in the left pane.
        swipe.update(.back, progress: 1)
        try await Task.sleep(for: .milliseconds(200))
        let swiping = try halves()
        #expect(swiping.left == idle.left)
        #expect(swiping.right != idle.right)
    }
}
