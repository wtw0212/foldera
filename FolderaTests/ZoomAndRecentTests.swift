import AppKit
import Carbon
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
    private func closeInformationWindow(for file: URL) {
        let script = NSAppleScript(source: """
        on closeTestInfoWindow(fileURL)
            set testFile to fileURL as alias
            tell application "Finder"
                if exists information window of testFile then close information window of testFile
            end tell
        end closeTestInfoWindow
        """)
        // Pass the URL as data, never as AppleScript source.
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(fileURL: file), at: 1)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: "closeTestInfoWindow"), forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        script?.executeAppleEvent(event, error: nil)
    }

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

    @Test func recentPageListsEverythingNewestFirstAndForgetsOnDelete() async throws {
        let preferences = try TestPreferences(), directory = try TestDirectory()
        let errors = ErrorCollector()
        let settings = AppSettings(defaults: preferences.defaults)
        let older = try directory.folder("Older"), file = try directory.file("Older/report.txt"), newer = try directory.folder("Newer")
        // Opening the server item's location connects, so it needs the stand-in server (never a real sign-in prompt).
        let remote = uniqueEndpoint()
        installFakeServer(remote)
        settings.recents.record(older, isFolder: true)
        settings.recents.record(file, isFolder: false)
        settings.recents.record(remote.url(path: "/srv/app.log"), isFolder: false)
        settings.recents.record(newer, isFolder: true)
        let model = ExplorerWindowModel(url: BrowserTab.recentURL, settings: settings)
        let tab = model.activeTab
        try await eventually { tab.items.count == 4 }
        #expect(tab.isRecent && !tab.isPage && !tab.acceptsItems && tab.parentURL == nil && tab.title == L10n.text("Recent"))
        #expect(tab.visibleItems.map(\.name) == ["Newer", "app.log", "report.txt", "Older"], "newest first, folders not grouped")
        tab.setSort(.name) // like clicking the Name column
        #expect(tab.visibleItems.map(\.name) == ["Older", "Newer", "report.txt", "app.log"], "choosing a sort leaves recency order")
        tab.setSort(.name)
        #expect(tab.visibleItems.map(\.name) == ["Newer", "Older", "app.log", "report.txt"])
        tab.searchText = "re"
        try await eventually { tab.visibleItems.map(\.name) == ["report.txt"] }
        tab.searchText = ""
        #expect(BrowserTab.editableAddress(of: BrowserTab.recentURL) == "Recent" && BrowserTab.pathName(of: BrowserTab.recentURL) == "Recent")
        #expect(Breadcrumbs.segments(for: BrowserTab.recentURL) == [BrowserTab.recentURL])
        #expect(FileDrop.operation(for: [file], into: BrowserTab.recentURL, modifiers: []) == nil)

        tab.selection = [file]
        let menu = ContextMenus.itemMenu(tab: tab) { _ in }.items.map(\.title)
        #expect(menu.contains(L10n.text("Open file location")) && menu.contains(L10n.text("Remove from Recent")))
        #expect(!menu.contains(L10n.text("Delete")) && !menu.contains(L10n.text("Rename")) && !menu.contains(L10n.text("Compress to ZIP file")))
        #expect(ContextMenus.backgroundMenu(tab: tab).items.map(\.title).contains(L10n.text("Clear Recent Items")))
        tab.beginRename()
        tab.newFolder()
        defer { withExtendedLifetime(directory) { closeInformationWindow(for: file) } }
        tab.showProperties()
        tab.openInTerminal()
        #expect(tab.renameRequest == nil && errors.errors.isEmpty)

        tab.trashSelection()
        #expect(FileManager.default.fileExists(atPath: file.path), "Delete on Recent only forgets the item")
        #expect(!settings.recents.items.map(\.url).contains(file) && tab.items.count == 3)

        tab.selection = [remote.url(path: "/srv/app.log")]
        tab.openItemLocation()
        #expect(tab.url == remote.url(path: "/srv") && tab.selection == [remote.url(path: "/srv/app.log")])
        tab.goBack()
        // The server folder that was just opened is now the newest recent item.
        try await eventually { tab.isRecent && tab.visibleItems.first?.url == remote.url(path: "/srv") && tab.items.count == 4 }
        tab.open(try #require(tab.visibleItems.first { $0.name == "Older" }))
        #expect(tab.url == older)
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
        #expect(try labels().contains(L10n.text("Recent")), "the Recent page is reachable before anything is opened")
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
