import Foundation
import Testing
@testable import Foldera

@MainActor
struct ViewModeTests {
    @Test func folderLayoutsPersistAndUnknownFoldersUseLastChoice() throws {
        let preferences = try TestPreferences()
        let first = URL(fileURLWithPath: "/first"), second = URL(fileURLWithPath: "/second")
        let defaults = preferences.defaults
        #expect(FolderViewModes.mode(for: first, defaults: defaults) == .details)
        FolderViewModes.set(.largeIcons, for: first, defaults: defaults)
        #expect(FolderViewModes.mode(for: second, defaults: defaults) == .largeIcons)
        FolderViewModes.set(.content, for: second, defaults: defaults)
        #expect(FolderViewModes.mode(for: first, defaults: defaults) == .largeIcons)
        #expect(FolderViewModes.mode(for: second, defaults: defaults) == .content)
        FolderViewModes.resetAll(defaults: defaults)
        #expect(FolderViewModes.mode(for: first, defaults: defaults) == .content)
        #expect(defaults.dictionary(forKey: "folderViewModes") == nil)
    }

    @Test func malformedStoredModesFallBackToDetails() throws {
        let preferences = try TestPreferences()
        let folder = URL(fileURLWithPath: "/folder")
        preferences.defaults.set("unknown", forKey: "defaultViewMode")
        #expect(FolderViewModes.mode(for: folder, defaults: preferences.defaults) == .details)
        preferences.defaults.set([folder.path: "unknown"], forKey: "folderViewModes")
        #expect(FolderViewModes.mode(for: folder, defaults: preferences.defaults) == .details)
    }

    @Test func shortcutsAndThumbnailPolicyCoverEveryLayout() {
        #expect(ViewMode.allCases.map(\.shortcutNumber) == Array(1...8))
        for mode in ViewMode.allCases {
            #expect(mode.showsThumbnails == [.extraLargeIcons, .largeIcons, .mediumIcons, .tiles, .content].contains(mode))
            #expect(mode.iconSize > 0 && !mode.symbol.isEmpty)
        }
    }

    @Test func navigationRestoresSortAndColumnsPerFolder() async throws {
        let directory = try TestDirectory(), preferences = try TestPreferences()
        let settings = AppSettings(defaults: preferences.defaults)
        let other = try directory.folder("other")
        let tab = BrowserTab(url: directory.url, settings: settings)
        tab.sort = SortOrder(field: .size, ascending: false)
        tab.columns.order = [.size, .name, .kind, .dateModified, .location]
        tab.columns.widths["name"] = 451
        tab.columns.toggle(.kind)
        let saved = tab.columns
        tab.navigate(to: other)
        #expect(tab.sort == SortOrder() && tab.columns == DetailColumns())
        tab.sort = SortOrder(field: .dateModified)
        tab.goBack()
        #expect(tab.sort == SortOrder(field: .size, ascending: false) && tab.columns == saved)
        let reopened = BrowserTab(url: directory.url, settings: settings)
        #expect(reopened.sort == tab.sort && reopened.columns == saved)
        FolderViewModes.resetAll(defaults: preferences.defaults)
        #expect(FolderViewModes.details(for: directory.url, defaults: preferences.defaults) == FolderDetails())
    }

    @Test func remoteHostsHaveSeparateViewsAndLocalLegacyLayoutsStillLoad() throws {
        let preferences = try TestPreferences(), defaults = preferences.defaults
        let first = try #require(URL(string: "sftp://user@one.example/folder"))
        let second = try #require(URL(string: "sftp://user@two.example/folder"))
        FolderViewModes.set(.tiles, for: first, defaults: defaults)
        FolderViewModes.set(.list, for: second, defaults: defaults)
        #expect(FolderViewModes.mode(for: first, defaults: defaults) == .tiles)
        let details = FolderDetails(sort: SortOrder(field: .kind, ascending: false))
        FolderViewModes.setDetails(details, for: first, defaults: defaults)
        #expect(FolderViewModes.details(for: first, defaults: defaults) == details)
        #expect(FolderViewModes.details(for: second, defaults: defaults) == FolderDetails())
        let local = URL(fileURLWithPath: "/legacy")
        defaults.set([local.path: ViewMode.content.rawValue], forKey: "folderViewModes")
        #expect(FolderViewModes.mode(for: local, defaults: defaults) == .content)
    }

    @Test func columnPreferencesKeepNameAndValidateStoredWidthsAndOrder() {
        var columns = DetailColumns(order: [.size, .size], widths: ["size": -1, "name": .infinity, "kind": 1_000_000])
        columns.toggle(.name)
        #expect(!columns.hidden.contains(.name))
        #expect(columns.ordered == [.size, .name, .location, .dateModified, .kind])
        #expect(columns.width(of: .size) == 60 && columns.width(of: .name) == FileColumn.name.width)
        #expect(columns.width(of: .kind) == 4096)
    }
}
