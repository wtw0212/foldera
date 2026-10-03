import AppKit
import SwiftUI
import Testing
import ViewInspector
@testable import Foldera

@MainActor
struct MenuTests {
    private func invoke(_ menu: NSMenu, _ title: String) throws {
        let item = try #require(menu.items.first { $0.title == title })
        let action = try #require(item.action)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
    }

    @Test func menuItemsRetainTheirHandlersCheckmarksAndDisabledActions() throws {
        let menu = NSMenu()
        var called = 0
        let enabled = menu.add("Enabled", symbol: "folder", checked: true) { called += 1 }
        let disabled = menu.add("Disabled", enabled: false) { called += 10 }
        menu.addSeparator()
        #expect(enabled.state == .on && enabled.image != nil && disabled.action == nil)
        #expect(menu.items.last?.isSeparatorItem == true)
        try invoke(menu, "Enabled")
        #expect(called == 1)
    }

    @Test func commandBarMenusApplySortingLayoutAndDisplayOptions() throws {
        let directory = try TestDirectory(), preferences = try TestPreferences()
        let settings = AppSettings(defaults: preferences.defaults)
        let tab = BrowserTab(url: directory.url, settings: settings), model = ExplorerWindowModel()
        let bar = CommandBar(model: model, tab: tab, settings: settings)
        for field in SortField.allCases {
            try invoke(bar.sortMenu(), field.title)
            #expect(tab.sort.field == field)
        }
        try invoke(bar.sortMenu(), L10n.text("Descending"))
        #expect(!tab.sort.ascending)
        try invoke(bar.sortMenu(), L10n.text("Ascending"))
        #expect(tab.sort.ascending)
        for mode in ViewMode.allCases {
            let menu = bar.viewMenu()
            let item = try #require(menu.items.first { $0.title == mode.title })
            #expect(item.keyEquivalent == String(mode.shortcutNumber) && item.keyEquivalentModifierMask == [.command, .option])
            try invoke(menu, mode.title)
            #expect(tab.viewMode == mode)
        }
        try invoke(bar.viewMenu(), L10n.text("Compact view"))
        let show = try #require(bar.viewMenu().items.first { $0.title == L10n.text("Show") }?.submenu)
        for title in ["Navigation pane", "Details pane", "Dual pane", "File name extensions", "Hidden items"] {
            try invoke(show, L10n.text(title))
        }
        #expect(settings.compactView && !settings.showNavigationPane && settings.sidePane == .details)
        #expect(model.isDualPane && !settings.showExtensions && settings.showHiddenFiles)
        #expect(try !bar.inspect().findAll(ViewType.Button.self).isEmpty)
    }

    @Test func selectionMenuSelectsInvertsAndClears() async throws {
        let directory = try TestDirectory()
        try directory.file("one.txt"); try directory.file("two.txt")
        let tab = BrowserTab(url: directory.url)
        try await eventually { !tab.isLoading }
        let bar = CommandBar(model: ExplorerWindowModel(), tab: tab)
        try invoke(bar.moreMenu(), L10n.text("Select all"))
        #expect(tab.selection.count == 2)
        try invoke(bar.moreMenu(), L10n.text("Invert selection"))
        #expect(tab.selection.isEmpty)
        tab.selectAll()
        try invoke(bar.moreMenu(), L10n.text("Select none"))
        #expect(tab.selection.isEmpty)
        try invoke(bar.moreMenu(), L10n.text("Copy path"))
        #expect(NSPasteboard.general.string(forType: .string) == directory.url.path)
    }

    @Test func folderContextMenuOffersNavigationPinningAndRename() async throws {
        let directory = try TestDirectory(), preferences = try TestPreferences()
        let quickAccess = QuickAccess(defaults: preferences.defaults)
        let folder = try directory.folder("nested")
        let tab = BrowserTab(url: directory.url)
        try await eventually { !tab.isLoading }
        tab.selection = [folder]
        var opened: URL?
        let menu = ContextMenus.itemMenu(tab: tab, quickAccess: quickAccess) { opened = $0 }
        try invoke(menu, L10n.text("Open in new tab"))
        #expect(opened == folder)
        try invoke(menu, L10n.text("Rename"))
        #expect(tab.renameRequest?.url == folder)
        try invoke(menu, L10n.text("Pin to Quick access"))
        #expect(quickAccess.isPinned(folder))
        try invoke(ContextMenus.itemMenu(tab: tab, quickAccess: quickAccess) { _ in }, L10n.text("Unpin from Quick access"))
        #expect(!quickAccess.isPinned(folder))
        try invoke(menu, L10n.text("Copy as path"))
        #expect(NSPasteboard.general.string(forType: .string) == folder.path)
        try invoke(menu, L10n.text("Open"))
        #expect(tab.url == folder)
    }

    @Test func contextMenusAdaptToFilesArchivesAndMultipleSelections() async throws {
        let directory = try TestDirectory()
        let text = try directory.file("note.txt"), first = try directory.file("first.zip"), second = try directory.file("second.zip")
        let tab = BrowserTab(url: directory.url)
        try await eventually { !tab.isLoading }
        tab.selection = [text]
        let fileMenu = ContextMenus.itemMenu(tab: tab) { _ in }
        #expect(fileMenu.items.contains { $0.title == L10n.text("Open with") && $0.submenu != nil })
        #expect(!fileMenu.items.contains { $0.title == L10n.text("Open in new tab") })
        tab.selection = [first]
        #expect(ContextMenus.itemMenu(tab: tab) { _ in }.items.contains { $0.title == L10n.format("Extract to “%@”", "first") })
        tab.selection = [first, second]
        let menu = ContextMenus.itemMenu(tab: tab) { _ in }
        #expect(menu.items.contains { $0.title == L10n.text("Extract each to separate folders") })
        try invoke(menu, L10n.format("rename.items.menu", 2))
        #expect(tab.bulkRenameItems?.count == 2)
    }

    @Test func backgroundMenuProvidesCheckedSortAndCreatesTextDocuments() async throws {
        let directory = try TestDirectory(), preferences = try TestPreferences()
        let quickAccess = QuickAccess(defaults: preferences.defaults)
        let tab = BrowserTab(url: directory.url)
        try await eventually { !tab.isLoading }
        let menu = ContextMenus.backgroundMenu(tab: tab, quickAccess: quickAccess)
        let sort = try #require(menu.items.first { $0.title == L10n.text("Sort by") }?.submenu)
        for field in SortField.allCases {
            try invoke(sort, field.title)
            #expect(tab.sort.field == field)
        }
        try invoke(sort, L10n.text("Descending")); #expect(!tab.sort.ascending)
        try invoke(sort, L10n.text("Ascending")); #expect(tab.sort.ascending)
        let new = try #require(menu.items.first { $0.title == L10n.text("New") }?.submenu)
        try invoke(new, L10n.text("Text Document"))
        #expect(tab.renameRequest != nil && FileOperations.exists(tab.renameRequest!.url))
        try invoke(menu, L10n.text("Pin to Quick access"))
        #expect(quickAccess.isPinned(directory.url))
        try invoke(ContextMenus.backgroundMenu(tab: tab, quickAccess: quickAccess), L10n.text("Unpin from Quick access"))
        #expect(!quickAccess.isPinned(directory.url))
    }

    @Test func breadcrumbSubfolderMenuFiltersPackagesAndHighlightsTheCurrentPath() throws {
        let directory = try TestDirectory()
        let chosen = try directory.folder("Folder 10")
        try directory.folder("Folder 2"); try directory.folder("Package.app"); try directory.file("note.txt")
        let tab = BrowserTab(url: chosen)
        let menu = SubfolderMenu.make(for: directory.url, tab: tab)
        #expect(menu.items.map(\.title) == ["Folder 2", "Folder 10"])
        #expect(menu.items[1].attributedTitle != nil)
        try invoke(menu, "Folder 2")
        #expect(tab.url == directory.path("Folder 2"))
        let empty = SubfolderMenu.make(for: chosen, tab: tab)
        #expect(empty.items.count == 1 && !empty.items[0].isEnabled)
        #expect(SubfolderMenu.make(for: BrowserTab.thisMacURL, tab: tab).items.count == VolumeMonitor.shared.volumes.count)
    }
}
