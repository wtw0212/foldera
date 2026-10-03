import Foundation
import Testing
@testable import Foldera

@MainActor
struct BrowserTabTests {
    private let directory: TestDirectory
    private let preferences: TestPreferences

    init() throws {
        directory = try TestDirectory()
        preferences = try TestPreferences()
    }

    private func loadedTab(at url: URL? = nil) async throws -> BrowserTab {
        let tab = BrowserTab(url: url ?? directory.url, settings: AppSettings(defaults: preferences.defaults))
        try await eventually { !tab.isLoading }
        try #require(tab.loadError == nil)
        return tab
    }

    @Test func navigationHistoryBackForwardAndBranching() throws {
        let a = try directory.folder("a"), b = try directory.folder("b"), c = try directory.folder("c")
        let tab = BrowserTab(url: directory.url)
        #expect(!tab.canGoBack && !tab.canGoForward)
        tab.navigate(to: a)
        tab.navigate(to: a.appendingPathComponent(".", isDirectory: true))
        #expect(tab.backHistory == [directory.url])
        tab.navigate(to: b)
        #expect(tab.backHistory == [a, directory.url])
        tab.goBack()
        #expect(tab.url == a && tab.forwardHistory == [b])
        tab.goForward()
        #expect(tab.url == b && !tab.canGoForward)
        tab.goBack()
        tab.navigate(to: c)
        #expect(tab.url == c && !tab.canGoForward && tab.backHistory == [a, directory.url])
    }

    @Test func historyMenuJumpsMaintainBothStacks() throws {
        let a = try directory.folder("a"), b = try directory.folder("b"), c = try directory.folder("c")
        let tab = BrowserTab(url: directory.url)
        [a, b, c].forEach(tab.navigate)
        tab.jump(toHistory: a, back: true)
        #expect(tab.url == a && tab.backHistory == [directory.url] && tab.forwardHistory == [b, c])
        tab.jump(toHistory: c, back: false)
        #expect(tab.url == c && tab.backHistory == [b, a, directory.url] && !tab.canGoForward)
    }

    @Test func goUpAndBackSelectTheChildFolder() async throws {
        let child = try directory.folder("child")
        let tab = try await loadedTab(at: child)
        tab.goUp()
        try await eventually { !tab.isLoading }
        #expect(tab.url == directory.url && tab.selection == [child])
        tab.navigate(to: child)
        try await eventually { !tab.isLoading }
        tab.goBack()
        try await eventually { !tab.isLoading }
        #expect(tab.selection == [child])
    }

    @Test func thisMacIsNotADirectoryAndRootGoesUpToDrives() {
        let tab = BrowserTab(url: BrowserTab.thisMacURL)
        #expect(tab.isThisMac && !tab.isLoading && tab.items.isEmpty && tab.loadError == nil)
        #expect(!tab.canGoUp && tab.parentURL == nil)
        tab.goUp()
        #expect(tab.url == BrowserTab.thisMacURL && !tab.canGoBack)
        let root = BrowserTab(url: URL(fileURLWithPath: "/"))
        #expect(root.parentURL == BrowserTab.thisMacURL)
        root.goUp()
        #expect(root.isThisMac && !root.isLoading)
    }

    @Test func naturalSortingAlwaysKeepsFoldersFirst() async throws {
        try directory.folder("z-folder")
        try directory.file("file10.txt")
        try directory.file("file2.txt")
        try directory.file("file1.txt")
        let tab = try await loadedTab()
        #expect(tab.visibleItems.map(\.name) == ["z-folder", "file1.txt", "file2.txt", "file10.txt"])
        tab.sort.ascending = false
        #expect(tab.visibleItems.map(\.name) == ["z-folder", "file10.txt", "file2.txt", "file1.txt"])
    }

    @Test func sizeDateAndKindSortingInvalidateCachedListing() async throws {
        try directory.folder("folder")
        let a = try directory.file("a.txt", contents: "1234")
        let b = try directory.file("b.txt", contents: "12")
        let c = try directory.file("c.txt", contents: "12")
        for (url, seconds) in [(a, 3.0), (b, 1.0), (c, 2.0)] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
        }
        let tab = try await loadedTab()
        tab.sort = SortOrder(field: .size)
        #expect(tab.visibleItems.map(\.name) == ["folder", "b.txt", "c.txt", "a.txt"])
        tab.sort.ascending = false
        #expect(tab.visibleItems.map(\.name) == ["folder", "a.txt", "c.txt", "b.txt"])
        tab.sort = SortOrder(field: .dateModified)
        #expect(tab.visibleItems.map(\.name) == ["folder", "b.txt", "c.txt", "a.txt"])
        tab.sort = SortOrder(field: .kind)
        #expect(tab.visibleItems.map(\.name) == ["folder", "a.txt", "b.txt", "c.txt"])
    }

    @Test func hiddenFilteringAndSelectedItemsUseTheVisibleListing() async throws {
        let visible = try directory.file("visible.txt"), hidden = try directory.file(".hidden.txt")
        let settings = AppSettings(defaults: preferences.defaults)
        let tab = BrowserTab(url: directory.url, settings: settings)
        try await eventually { !tab.isLoading }
        tab.selection = [visible, hidden]
        #expect(Set(tab.items.map(\.url)) == [visible, hidden])
        #expect(tab.visibleItems.map(\.url) == [visible] && tab.selectedItems.map(\.url) == [visible])
        settings.showHiddenFiles = true
        #expect(Set(tab.visibleItems.map(\.url)) == [visible, hidden])
        #expect(Set(tab.selectedItems.map(\.url)) == [visible, hidden])
    }

    @Test func reloadPrunesDeletedSelectionsAndRecoversFromMissingDirectory() async throws {
        let file = try directory.file("note.txt")
        let tab = try await loadedTab()
        tab.selection = [file]
        try FileManager.default.removeItem(at: file)
        tab.reload()
        try await eventually { !tab.isLoading }
        #expect(tab.selection.isEmpty && tab.items.isEmpty)
        let missing = directory.path("missing")
        tab.navigate(to: missing)
        try await eventually { !tab.isLoading }
        #expect(tab.loadError != nil && tab.items.isEmpty)
        try directory.folder("missing")
        try directory.file("missing/restored.txt")
        tab.reload()
        try await eventually { !tab.isLoading }
        #expect(tab.loadError == nil && tab.items.map(\.name) == ["restored.txt"])
    }

    @Test func rapidNavigationCannotApplyAnOlderLoad() async throws {
        let first = try directory.folder("first"), second = try directory.folder("second")
        try directory.file("first/old.txt")
        try directory.file("second/current.txt")
        let tab = BrowserTab(url: first)
        tab.navigate(to: second)
        try await eventually { !tab.isLoading }
        #expect(tab.url == second && tab.items.map(\.name) == ["current.txt"])
    }

    @Test func searchDebouncesReplacesOldQueryAndClearsOnNavigation() async throws {
        try directory.file("alpha.txt")
        try directory.file("nested/beta.txt")
        let tab = try await loadedTab()
        tab.searchText = "alpha"
        tab.searchText = "beta"
        try await eventually { !tab.isSearching }
        #expect(tab.isSearchActive && tab.visibleItems.map(\.name) == ["beta.txt"])
        tab.searchText = "no-match"
        try await eventually { !tab.isSearching }
        #expect(tab.searchResults.isEmpty && tab.visibleItems.isEmpty)
        tab.searchText = "   "
        #expect(!tab.isSearchActive && tab.searchResults.isEmpty)
        tab.searchText = "alpha"
        tab.navigate(to: directory.path("nested"))
        try await eventually { !tab.isLoading && !tab.isSearching }
        #expect(tab.searchText.isEmpty && tab.selection.isEmpty && tab.visibleItems.map(\.name) == ["beta.txt"])
    }

    @Test func directoryWatcherRefreshesNewFiles() async throws {
        let tab = try await loadedTab()
        try directory.file("arrived.txt")
        try await eventually(timeout: .seconds(10)) { tab.items.contains { $0.name == "arrived.txt" } }
    }
}
