import AppKit
import SwiftUI
import Testing
import ViewInspector
@testable import Foldera

@MainActor
struct ZoomTests {
    @Test func zoomStepsThroughLayoutsAndStopsAtTheEnds() {
        #expect(ViewMode.details.zoomed(in: true) == .list)
        #expect(ViewMode.list.zoomed(in: true) == .smallIcons)
        #expect(ViewMode.largeIcons.zoomed(in: true) == .extraLargeIcons)
        #expect(ViewMode.extraLargeIcons.zoomed(in: true) == .extraLargeIcons)
        #expect(ViewMode.details.zoomed(in: false) == .details)
        #expect(ViewMode.smallIcons.zoomed(in: false) == .list)
        #expect(ViewMode.tiles.zoomed(in: true) == .largeIcons && ViewMode.content.zoomed(in: false) == .smallIcons)
    }

    @Test func tabsZoomTheirFolderButNotPages() async throws {
        let directory = try TestDirectory(), preferences = try TestPreferences()
        let settings = AppSettings(defaults: preferences.defaults)
        let tab = BrowserTab(url: directory.url, settings: settings)
        #expect(tab.viewMode == .details)
        let focus = tab.focusListToken
        tab.zoom(in: true)
        tab.zoom(in: true)
        #expect(tab.viewMode == .smallIcons && tab.focusListToken == focus + 2)
        #expect(FolderViewModes.mode(for: directory.url, defaults: preferences.defaults) == .smallIcons)
        tab.zoom(in: false)
        #expect(tab.viewMode == .list)
        let page = BrowserTab(url: BrowserTab.thisMacURL, settings: settings)
        let mode = page.viewMode
        page.zoom(in: true)
        #expect(page.viewMode == mode)
    }

    @Test func mouseWheelsStepPerNotchTrackpadsPerDistanceAndPinchesPerAmount() {
        var gesture = ZoomGesture()
        #expect(gesture.step(scroll: 1, precise: false, momentum: false, began: false) == 1)
        #expect(gesture.step(scroll: -3, precise: false, momentum: false, began: false) == -1)
        #expect(gesture.step(scroll: 0, precise: false, momentum: false, began: false) == 0)
        #expect(gesture.step(scroll: 25, precise: true, momentum: false, began: true) == 0)
        #expect(gesture.step(scroll: 20, precise: true, momentum: false, began: false) == 1)
        #expect(gesture.step(scroll: 100, precise: true, momentum: true, began: false) == 0, "momentum doesn't keep zooming")
        #expect(gesture.step(scroll: 30, precise: true, momentum: false, began: false) == 0)
        #expect(gesture.step(scroll: -30, precise: true, momentum: false, began: true) == 0, "a new gesture starts from zero")
        #expect(gesture.step(scroll: -15, precise: true, momentum: false, began: false) == -1)
        #expect(gesture.step(magnification: 0.1, began: true) == 0)
        #expect(gesture.step(magnification: 0.2, began: false) == 1)
        #expect(gesture.step(magnification: -0.3, began: false) == -1)
    }

    @Test func commandScrollOverTheListZoomsAndPlainScrollDoesNot() throws {
        let directory = try TestDirectory(), preferences = try TestPreferences()
        let tab = BrowserTab(url: directory.url, settings: AppSettings(defaults: preferences.defaults))
        let table = FileTableView()
        let commands = TabCommands(tab: tab)
        table.commands = commands
        func wheel(_ lines: Int32, command: Bool) throws -> NSEvent {
            let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0))
            event.flags = command ? .maskCommand : []
            return try #require(NSEvent(cgEvent: event))
        }
        let plain = try wheel(1, command: false)
        #expect(!ZoomGesture.isZoomScroll(plain))
        table.scrollWheel(with: plain)
        #expect(tab.viewMode == .details)
        let up = try wheel(1, command: true)
        #expect(ZoomGesture.isZoomScroll(up))
        table.scrollWheel(with: up)
        let expected: ViewMode = up.isDirectionInvertedFromDevice ? .details : .list
        #expect(tab.viewMode == expected)
        let grid = FileCollectionView()
        grid.commands = commands
        grid.scrollWheel(with: try wheel(-1, command: true))
        grid.scrollWheel(with: plain)
        #expect(ViewMode.zoomOrder.contains(tab.viewMode))
    }
}

/// Forwards zoom to a tab, like the list and grid coordinators.
@MainActor
private final class TabCommands: FileViewCommands {
    let tab: BrowserTab
    init(tab: BrowserTab) { self.tab = tab }
    func openSelection() {}
    func beginRename() {}
    func goUp() {}
    func goBack() {}
    func trashSelection() {}
    func cutSelection() {}
    func copySelection() {}
    func paste() {}
    func toggleQuickLook() {}
    func zoom(in zoomIn: Bool) { tab.zoom(in: zoomIn) }
    func openInBackgroundTab(index: Int) {}
    var hasSelection: Bool { false }
    var canPaste: Bool { false }
    func contextMenu(forRow row: Int) -> NSMenu? { nil }
}

@MainActor
struct RecentItemsTests {
    @Test func recentItemsAreNewestFirstDedupedCappedAndPersisted() throws {
        let preferences = try TestPreferences(), directory = try TestDirectory()
        let recents = RecentItems(defaults: preferences.defaults)
        let folder = try directory.folder("Project"), file = try directory.file("notes.txt")
        let remote = RemoteEndpoint(host: "h", username: "u").url(path: "/srv/site")
        recents.record(folder, isFolder: true)
        recents.record(file, isFolder: false)
        recents.record(remote, isFolder: true)
        recents.record(folder.appendingPathComponent("/"), isFolder: true)
        recents.record(BrowserTab.thisMacURL, isFolder: true)
        #expect(recents.items.map(\.url) == [folder, remote, file])
        #expect(recents.items.map(\.name) == ["Project", "site", "notes.txt"])
        #expect(RecentItems(defaults: preferences.defaults).items == recents.items)

        #expect(recents.visible(2).map(\.url) == [folder, remote] && recents.visible(0).isEmpty)
        try FileManager.default.removeItem(at: file)
        #expect(recents.visible(5).map(\.url) == [folder, remote], "deleted local items are skipped; server items stay")
        recents.remove(remote)
        #expect(recents.items.map(\.url) == [folder, file])
        for index in 0..<60 { recents.record(directory.path("f\(index)"), isFolder: true) }
        #expect(recents.items.count == RecentItems.capacity && recents.items.first?.url == directory.path("f59"))
        recents.clear()
        #expect(recents.items.isEmpty && RecentItems(defaults: preferences.defaults).items.isEmpty)
    }

    @Test func navigatingAndNewTabsRecordFolders() async throws {
        let preferences = try TestPreferences(), directory = try TestDirectory()
        let settings = AppSettings(defaults: preferences.defaults)
        #expect(settings.recentItemsCount == 5)
        settings.recentItemsCount = 3
        #expect(AppSettings(defaults: preferences.defaults).recentItemsCount == 3)
        let a = try directory.folder("a"), b = try directory.folder("a/b")
        let model = ExplorerWindowModel(url: directory.url, settings: settings)
        model.activeTab.navigate(to: a)
        model.activeTab.navigate(to: b)
        model.activeTab.goBack()
        model.newTab(url: directory.url, activate: false)
        model.activeTab.navigate(to: BrowserTab.networkURL)
        #expect(settings.recents.items.map(\.url) == [directory.url, b, a])
        model.activeTab.openRecent(try #require(settings.recents.items.last))
        #expect(model.activeTab.url == a && settings.recents.items.first?.url == a)
    }

    @Test func navigationPaneShowsTheConfiguredNumberOfRecentItems() throws {
        let preferences = try TestPreferences(), directory = try TestDirectory()
        let settings = AppSettings(defaults: preferences.defaults)
        let model = ExplorerWindowModel(url: directory.url, settings: settings)
        let sites = SFTPSites(defaults: preferences.defaults, secrets: MemorySecrets())
        func labels() throws -> [String] {
            try NavigationPane(model: model, tab: model.activeTab, sites: sites, settings: settings)
                .inspect().findAll(ViewType.Text.self).map { try $0.string() }
        }
        #expect(try !labels().contains(L10n.text("Recent")), "no section until something is opened")
        let file = try directory.file("report.pdf")
        let remote = RemoteEndpoint(host: "h", username: "u")
        settings.recents.record(try directory.folder("Alpha"), isFolder: true)
        settings.recents.record(file, isFolder: false)
        settings.recents.record(remote.url(path: "/srv/www"), isFolder: true)
        settings.recents.record(remote.url(path: "/srv/www/index.html"), isFolder: false)
        settings.recentItemsCount = 3
        let shown = try labels()
        #expect(shown.contains(L10n.text("Recent")) && shown.contains("index.html") && shown.contains("www") && shown.contains("report.pdf"))
        #expect(!shown.contains("Alpha"))
        settings.recentItemsCount = 0
        #expect(try !labels().contains(L10n.text("Recent")))

        for item in settings.recents.items { #expect(NavigationPane.icon(for: item).size.width > 0) }
        let host = NSHostingView(rootView: NavigationPane(model: model, tab: model.activeTab, sites: sites, settings: settings))
        settings.recentItemsCount = 5
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 900)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 0)
    }
}
