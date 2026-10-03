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
}
